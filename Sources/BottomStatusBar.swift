import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation
import SwiftUI

/// One styled stretch of the status bar's line.
struct BottomStatusBarRun: Equatable {
    enum Color: Equatable {
        /// One of the 16 ANSI colors.
        case palette(Int)
        case rgb(UInt8, UInt8, UInt8)
    }

    var text: String
    var color: Color?
    var bold = false
    var dim = false
    /// Target of the OSC 8 hyperlink the run sits inside.
    var link: String?

    /// Splits one line of program output into runs. SGR colors, bold, dim and
    /// OSC 8 hyperlinks are kept; every other escape sequence is dropped.
    static func parse(_ line: String) -> [BottomStatusBarRun] {
        var runs: [BottomStatusBarRun] = []
        var style = BottomStatusBarRun(text: "")
        var text = String.UnicodeScalarView()

        func flush() {
            guard !text.isEmpty else { return }
            if var last = runs.last {
                last.text = ""
                if last == style {
                    runs[runs.count - 1].text += String(text)
                    text = String.UnicodeScalarView()
                    return
                }
            }
            var run = style
            run.text = String(text)
            runs.append(run)
            text = String.UnicodeScalarView()
        }

        let scalars = Array(line.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "\u{1b}" else {
                if scalars[i].value >= 0x20 { text.append(scalars[i]) }
                i += 1
                continue
            }
            let introducer = i + 1 < scalars.count ? scalars[i + 1] : nil
            i += 2
            if introducer == "[" {
                let start = i
                while i < scalars.count, !(0x40...0x7e).contains(scalars[i].value) { i += 1 }
                guard i < scalars.count else { break }
                if scalars[i] == "m" {
                    flush()
                    applySGR(String(String.UnicodeScalarView(scalars[start..<i])), to: &style)
                }
                i += 1
            } else if introducer == "]" {
                let start = i
                while i < scalars.count, scalars[i] != "\u{07}", scalars[i] != "\u{1b}" { i += 1 }
                let body = String(String.UnicodeScalarView(scalars[start..<i]))
                // Terminated by BEL or by ESC \.
                if i < scalars.count { i += scalars[i] == "\u{07}" ? 1 : 2 }
                if body.hasPrefix("8;") {
                    flush()
                    // 8;params;URI, where an empty URI closes the link.
                    let uri = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                        .dropFirst(2).first.map(String.init) ?? ""
                    style.link = uri.isEmpty ? nil : uri
                }
            }
        }
        flush()
        return runs
    }

    private static func applySGR(_ parameters: String, to style: inout BottomStatusBarRun) {
        let codes = parameters.isEmpty
            ? [0]
            : parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0:
                // A reset ends colors and weight, not the hyperlink.
                style = BottomStatusBarRun(text: "", link: style.link)
            case 1: style.bold = true
            case 2: style.dim = true
            case 22: style.bold = false; style.dim = false
            case 30...37: style.color = .palette(codes[i] - 30)
            case 39: style.color = nil
            case 90...97: style.color = .palette(codes[i] - 90 + 8)
            case 38, 48:
                // Extended colors; backgrounds are parsed only so their arguments are skipped.
                if i + 4 < codes.count, codes[i + 1] == 2 {
                    if codes[i] == 38 {
                        style.color = .rgb(
                            UInt8(clamping: codes[i + 2]),
                            UInt8(clamping: codes[i + 3]),
                            UInt8(clamping: codes[i + 4])
                        )
                    }
                    i += 4
                } else if i + 2 < codes.count, codes[i + 1] == 5 {
                    if codes[i] == 38, codes[i + 2] < 16 { style.color = .palette(codes[i + 2]) }
                    i += 2
                }
            default: break
            }
            i += 1
        }
    }
}

/// Runs `statusBar.command` once for the whole app and publishes the last line it
/// printed. Writing a newline to its stdin asks it to refresh. When it exits it
/// is started again 10 seconds later, so a command that prints one line and
/// quits works as a poll.
@MainActor
final class BottomStatusBarFeed: ObservableObject {
    static let shared = BottomStatusBarFeed()

    @Published private(set) var runs: [BottomStatusBarRun] = []

    private var command = ""
    private var process: Process?
    private var input: FileHandle?
    private var pending = Data()
    private var printedSinceLaunch = false
    /// Bumped on every launch and stop so callbacks from a replaced process are ignored.
    private var generation = 0

    /// Starts `newCommand` in place of whatever ran before. Empty stops it and hides the bar.
    func run(_ newCommand: String) {
        guard newCommand != command else { return }
        command = newCommand
        stop()
        runs = []
        if !command.isEmpty { launch() }
    }

    func requestRefresh() {
        try? input?.write(contentsOf: Data("\n".utf8))
    }

    private func stop() {
        generation += 1
        // Closing stdin is what stops a program that ignores SIGTERM in a child.
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        pending.removeAll()
    }

    private func launch() {
        generation += 1
        let launchGeneration = generation
        printedSinceLaunch = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        // Apps opened from Finder get launchd's PATH, which has no Homebrew.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        proc.environment = environment

        let stdout = Pipe()
        let stdin = Pipe()
        proc.standardOutput = stdout
        proc.standardInput = stdin
        proc.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let chunk):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == launchGeneration else { return }
                        self.ingest(chunk)
                    }
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == launchGeneration else { return }
                    self.process = nil
                    self.input = nil
                    if !self.printedSinceLaunch { self.showFailure() }
                    self.scheduleRelaunch()
                }
            }
        }

        do {
            try proc.run()
            process = proc
            input = stdin.fileHandleForWriting
        } catch {
            showFailure()
            scheduleRelaunch()
        }
    }

    private func scheduleRelaunch() {
        let pendingGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == pendingGeneration, self.process == nil, !self.command.isEmpty else { return }
                self.launch()
            }
        }
    }

    private func showFailure() {
        runs = [BottomStatusBarRun(
            text: String(localized: "statusBar.error.noOutput", defaultValue: "Status bar command exited without printing a line"),
            color: .palette(1)
        )]
    }

    private func ingest(_ chunk: Data) {
        pending.append(chunk)
        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else {
            // A program that never ends its line would otherwise grow this forever.
            if pending.count > 65_536 { pending.removeAll() }
            return
        }
        let complete = pending[pending.startIndex..<lastNewline]
        pending.removeSubrange(pending.startIndex...lastNewline)
        let newest = complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).last
        guard let newest, let text = String(data: Data(newest), encoding: .utf8) else { return }
        printedSinceLaunch = true
        runs = BottomStatusBarRun.parse(text)
    }
}

struct BottomStatusBar: View {
    /// Runs the `actions` entry a `cmux-action:<id>` link names; false when there is none.
    let runAction: @MainActor (String) -> Bool

    private static let settings = StatusBarCatalogSection()

    @ObservedObject private var feed = BottomStatusBarFeed.shared
    @AppStorage(BottomStatusBar.settings.command.userDefaultsKey) private var command = ""
    @AppStorage(BottomStatusBar.settings.fontSize.userDefaultsKey) private var fontSize = 11.0
    @AppStorage(BottomStatusBar.settings.alignment.userDefaultsKey)
    private var alignment = SessionContentAlignment.left.rawValue

    var body: some View {
        Group {
            if feed.runs.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                bar
            }
        }
        .onAppear { feed.run(command) }
        .onChange(of: command) { _, newCommand in feed.run(newCommand) }
    }

    private var bar: some View {
        let size = CGFloat(min(max(fontSize, StatusBarCatalogSection.fontSizeRange.lowerBound), StatusBarCatalogSection.fontSizeRange.upperBound))
        return ViewThatFits(in: .horizontal) {
            line(size: size).frame(maxWidth: .infinity, alignment: frameAlignment)
            // Wider than the window: keep the start in view and cut the end.
            line(size: size).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: size + 11)
        .clipped()
        .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { feed.requestRefresh() }
        .help(String(localized: "statusBar.help.refresh", defaultValue: "Click to refresh"))
    }

    private var frameAlignment: Alignment {
        switch SessionContentAlignment(rawValue: alignment) ?? .left {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func line(size: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(linkSegments.enumerated()), id: \.offset) { _, segment in
                let label = Text(attributed(segment.runs, size: size))
                if let link = segment.link {
                    label
                        .onTapGesture { open(link) }
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                } else {
                    label
                }
            }
        }
        .font(.system(size: size, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }

    /// Consecutive runs that share a link, so each link is one click target.
    private var linkSegments: [(link: String?, runs: [BottomStatusBarRun])] {
        var segments: [(link: String?, runs: [BottomStatusBarRun])] = []
        for run in feed.runs {
            if let last = segments.last, last.link == run.link {
                segments[segments.count - 1].runs.append(run)
            } else {
                segments.append((run.link, [run]))
            }
        }
        return segments
    }

    private func attributed(_ runs: [BottomStatusBarRun], size: CGFloat) -> AttributedString {
        var output = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let color = run.color.map(Self.nsColor) {
                piece.foregroundColor = Color(nsColor: run.dim ? color.withAlphaComponent(0.6) : color)
            } else if run.dim {
                piece.foregroundColor = .secondary
            }
            if run.bold { piece.font = .system(size: size, weight: .semibold, design: .monospaced) }
            output.append(piece)
        }
        return output
    }

    private func open(_ link: String) {
        let actionScheme = "cmux-action:"
        if link.hasPrefix(actionScheme) {
            let id = String(link.dropFirst(actionScheme.count))
            if runAction(id.removingPercentEncoding ?? id) { return }
        } else if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
            return
        }
        NSSound.beep()
    }

    private static func nsColor(_ color: BottomStatusBarRun.Color) -> NSColor {
        switch color {
        case .palette(let index):
            return ansiPalette[min(max(index, 0), ansiPalette.count - 1)]
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    private static let ansiPalette: [NSColor] = [
        .black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .lightGray,
        .darkGray, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .white,
    ]
}
