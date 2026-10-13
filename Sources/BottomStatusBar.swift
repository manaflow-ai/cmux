import AppKit
import CmuxSettings
import CmuxStatusBar
import Foundation
import SwiftUI

struct BottomStatusBar: View {
    /// Runs the `actions` entry a `cmux-action:<id>` link names; false when there is none.
    let runAction: @MainActor (String) -> Bool

    private static let settings = StatusBarCatalogSection()

    /// Owned by AppDelegate and shared by every window, so the command runs once.
    @Environment(StatusBarFeed.self) private var feed: StatusBarFeed?
    @AppStorage(BottomStatusBar.settings.command.userDefaultsKey) private var command = ""
    @AppStorage(BottomStatusBar.settings.fontSize.userDefaultsKey) private var fontSize = 11.0
    @AppStorage(BottomStatusBar.settings.alignment.userDefaultsKey)
    private var alignment = SessionContentAlignment.left.rawValue

    var body: some View {
        Group {
            if let feed, feed.content != .hidden {
                bar(feed)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onAppear { feed?.run(command) }
        .onChange(of: command) { _, newCommand in feed?.run(newCommand) }
    }

    private func bar(_ feed: StatusBarFeed) -> some View {
        let segments = Self.segments(feed.content)
        let size = CGFloat(min(max(fontSize, StatusBarCatalogSection.fontSizeRange.lowerBound), StatusBarCatalogSection.fontSizeRange.upperBound))
        return ViewThatFits(in: .horizontal) {
            line(segments, size: size).frame(maxWidth: .infinity, alignment: frameAlignment)
            // Wider than the window: keep the start in view and cut the end.
            line(segments, size: size).frame(maxWidth: .infinity, alignment: .leading)
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

    private func line(_ segments: [StatusBarSegment], size: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let label = Text(attributed(segment.runs, size: size))
                if let link = segment.link {
                    label
                        .onTapGesture { open(link) }
                        .backport.pointerStyle(.link)
                } else {
                    label
                }
            }
        }
        .font(.system(size: size, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }

    private static func segments(_ content: StatusBarFeed.Content) -> [StatusBarSegment] {
        switch content {
        case .hidden:
            return []
        case .line(let segments):
            return segments
        case .silentExit:
            let message = String(localized: "statusBar.error.noOutput", defaultValue: "Status bar command exited without printing a line")
            return [StatusBarSegment(link: nil, runs: [StatusBarRun(text: message, color: .palette(1))])]
        }
    }

    private func attributed(_ runs: [StatusBarRun], size: CGFloat) -> AttributedString {
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

    private static func nsColor(_ color: StatusBarRun.Color) -> NSColor {
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
