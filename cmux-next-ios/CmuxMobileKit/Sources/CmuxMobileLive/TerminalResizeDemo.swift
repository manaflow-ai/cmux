// DEBUG and Demo builds only: the resize demo is never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import SwiftUI

/// DEBUG only. Launch with `-CmuxMobileResizeDemo` to watch the phone and a
/// Mac share one terminal's size through the real pipeline: the terminal page,
/// `DaemonTerminalSession` and `DaemonClient`. Only the Mac is faked: its own
/// pane is 120x40 and its screen is an agent transcript laid out at whatever
/// grid the PTY has, as Claude Code lays out its own text.
///
/// The driver's steps (the `debug.resize-demo` label, for UI tests):
/// - `phone`: attached and claiming; the Mac answers at the phone's grid.
/// - `lease`: while the page is on screen, the Mac's own grid comes back (the
///   phone's lease ended over a slow link) and replays its 120-column screen.
///   The phone should keep its frame, claim its grid again, and draw the
///   Mac's answer at the phone's grid (400 ms later); it should never draw
///   the 120-column screen cut at the right edge.
/// - `background`, `foreground`: the app leaves (the size is released, the
///   Mac replays its own grid to the hidden page) and comes back (claimed again).
/// - `done.<claims>.<releases>`: the `resize-surface` and
///   `release-surface-size` requests the Mac saw.
public struct TerminalResizeDemoRoot: View {
    @State private var demo = TerminalResizeDemo()

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileResizeDemo") }

    public var body: some View {
        NavigationStack {
            TerminalScreen(model: demo.model)
        }
        .overlay(alignment: .topLeading) {
            Text(demo.step)
                .font(.system(size: 2))
                .foregroundStyle(.clear)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.resize-demo")
        }
        .task { await demo.run() }
    }
}

@MainActor @Observable
final class TerminalResizeDemo {
    let model: TerminalModel
    private(set) var step = "start"
    @ObservationIgnored private let mac: ResizeDemoMac

    init() {
        let mac = ResizeDemoMac()
        self.mac = mac
        let session = DaemonTerminalSession(
            surface: 1,
            clientInfo: ["name": "demo iPhone", "kind": "ios", "device_kind": "iphone", "device_name": "demo iPhone"],
            open: { DaemonClient(channel: mac.main) }
        )
        model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "claude — Mac")
    }

    private func mark(_ label: String) {
        step = label
        NSLog("[resize-demo] %@", label)
    }

    func run() async {
        let clock = ContinuousClock()
        while !model.connectionState.isAttached { try? await clock.sleep(for: .milliseconds(50)) }
        try? await clock.sleep(for: .seconds(2))
        mark("phone")
        try? await clock.sleep(for: .seconds(2))
        mark("lease")
        mac.pushMacGrid()
        try? await clock.sleep(for: .seconds(4))
        mark("background")
        model.setAppActive(false)
        try? await clock.sleep(for: .seconds(2))
        mark("foreground")
        model.setAppActive(true)
        try? await clock.sleep(for: .seconds(3))
        mark("done.\(mac.claims).\(mac.releases)")
    }
}

/// The scripted Mac: answers the phone's attach and claims at the phone's
/// grid, a release with its own 120x40 grid, and replays an agent
/// transcript laid out at the grid it answers with.
final class ResizeDemoMac: @unchecked Sendable {
    static let macGrid = (columns: 120, rows: 40)
    let main = FloodChannel(id: 1)
    private let lock = NSLock()
    private var phone: (columns: Int, rows: Int)?
    private var claimCount = 0
    private var releaseCount = 0

    var claims: Int { lock.withLock { claimCount } }
    var releases: Int { lock.withLock { releaseCount } }

    init() {
        main.onSend = { [weak self] line in self?.request(line) }
    }

    /// The Mac's own grid, unasked (the phone's lease ended).
    func pushMacGrid() {
        lock.withLock { answersNextClaim = true }
        main.push([Self.event("resized", Self.macGrid.columns, Self.macGrid.rows)])
    }

    private func request(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return }
        let reply = Self.line(["id": id, "ok": true, "data": cmd == "identify"
            ? ["capabilities": ["attach-initial-size", "size-lease-v2", "size-lease-v1"]] as [String: Any]
            : [String: Any]()])
        switch cmd {
        case "attach-surface":
            let size = (object["cols"] as? Int).flatMap { columns in (object["rows"] as? Int).map { (columns, $0) } }
            if let size { lock.withLock { phone = size } }
            let grid = size ?? Self.macGrid
            main.push([Self.event("vt-state", grid.0, grid.1), reply])
        case "resize-surface":
            guard let columns = object["cols"] as? Int, let rows = object["rows"] as? Int else {
                main.push([reply])
                return
            }
            let changed: Bool = lock.withLock {
                claimCount += 1
                defer { phone = (columns, rows) }
                return phone.map { $0.columns != columns || $0.rows != rows } ?? true
            }
            main.push([reply])
            // The claim's answer, a round trip later; a lease refresh at the
            // same size answers nothing, as the daemon does.
            if changed || lock.withLock({ answersNextClaim }) {
                lock.withLock { answersNextClaim = false }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [main] in
                    main.push([Self.event("resized", columns, rows)])
                }
            }
        case "release-surface-size":
            lock.withLock {
                releaseCount += 1
                answersNextClaim = true
            }
            main.push([reply, Self.event("resized", Self.macGrid.columns, Self.macGrid.rows)])
        default:
            main.push([reply])
        }
    }

    /// After the Mac took its own grid back, the phone's next claim resizes.
    private var answersNextClaim = false

    private static func event(_ name: String, _ columns: Int, _ rows: Int) -> Data {
        line(["event": name, "surface": 1, "cols": columns, "rows": rows,
              name == "resized" ? "replay" : "data": Data(transcript(columns: columns).utf8).base64EncodedString()])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// An agent transcript laid out at `columns`, with hard line breaks, as
    /// Claude Code writes its own text: a wide grid's lines run past a
    /// narrower screen.
    static func transcript(columns: Int) -> String {
        let width = max(columns - 2, 10)
        func wrap(_ text: String, first: String, rest: String) -> [String] {
            var lines: [String] = []
            var current = first
            for word in text.split(separator: " ") {
                if current.count + word.count + 1 > width, current.count > first.count {
                    lines.append(current)
                    current = rest
                }
                current += (current == first || current == rest ? "" : " ") + word
            }
            lines.append(current)
            return lines
        }
        var rows: [String] = []
        let paragraphs = [
            "I read the sizing code and found why the Mac pane stayed at the iPhone's width after the app went to the background.",
            "The release waited behind a request whose answer came back behind the terminal's output, so iOS suspended the app first.",
            "Now the release goes out at once, the lease is 8 seconds, and the phone never draws a grid it did not ask for.",
        ]
        for paragraph in paragraphs {
            rows += wrap(paragraph, first: "\u{1B}[1m●\u{1B}[0m ", rest: "  ")
            rows.append("")
            rows.append("  \u{1B}[2mRead 3 files, ran 2 shell commands\u{1B}[0m")
            rows.append("")
        }
        let rule = "\u{1B}[2m" + String(repeating: "─", count: columns) + "\u{1B}[0m"
        rows += [rule, "❯ ", rule, "  \u{1B}[31m⏵⏵ bypass permissions on\u{1B}[0m · laid out at \(columns) columns"]
        return "\u{1B}[H\u{1B}[2J" + rows.joined(separator: "\r\n")
    }
}
#endif
