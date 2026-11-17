// DEBUG and Demo builds only: never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import SwiftUI

/// DEBUG only. Launch with `-CmuxMobileHistoryWindowDemo` to scroll a long
/// Mac history through the real pipeline: `DaemonClient`,
/// `DaemonTerminalSession` (its tail and window fetches,
/// `attach-replay-history-window-v1`), the real terminal screen and Ghostty.
/// Only the Mac is faked: a daemon whose terminal holds
/// `-CmuxMobileHistoryWindowDemoRows` history rows (default 30,000), each
/// numbered from 000000, and answers `attach-surface` the way cmux-tui's
/// `HistoryWindow::plan` does: the newest rows of a tail, or a window of at
/// most 10,000 rows far above the screen (a gap shorter than the window goes
/// as rows down to the screen).
///
/// A caption at the top (`terminal.historyDemo.state`) says what the mirror
/// holds, for `TerminalHistoryWindowUITests`.
public struct TerminalHistoryWindowDemoRoot: View {
    @State private var demo = TerminalHistoryWindowDemo()

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileHistoryWindowDemo") }

    public var body: some View {
        NavigationStack {
            TerminalScreen(model: demo.model)
                .overlay(alignment: .top) {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        Text(demo.state)
                            .font(.caption2.monospaced())
                            .padding(4)
                            .background(.yellow.opacity(0.85))
                            .foregroundStyle(.black)
                            .accessibilityIdentifier("terminal.historyDemo.state")
                    }
                    .allowsHitTesting(false)
                }
                // As `TerminalTabPage` does for the app's own pages: the page
                // is on screen and taking input, so it claims the phone's
                // size. Without it the session held the Mac's 80x40 grid and
                // every byte after it (`TerminalReclaimHold`), and the page
                // stayed blank with nothing to scroll down through.
                .onAppear { demo.model.setPageShown(true) }
                .onDisappear { demo.model.setPageShown(false) }
        }
    }
}

@MainActor
final class TerminalHistoryWindowDemo {
    let model: TerminalModel
    private let session: DaemonTerminalSession
    private let daemon: HistoryWindowDaemon

    init() {
        let rows = UserDefaults.standard.integer(forKey: "CmuxMobileHistoryWindowDemoRows")
        daemon = HistoryWindowDaemon(historyRows: rows > 0 ? rows : 30_000)
        let daemon = daemon
        session = DaemonTerminalSession(
            surface: 1,
            // A channel per open, as the link opens one per attach: a history
            // fetch is a second attach, and closing the one it replaces must
            // not end the new one's stream.
            open: { DaemonClient(channel: daemon.openChannel(), eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) },
            openInput: { DaemonClient(channel: daemon.openChannel(), eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) }
        )
        model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "history window demo")
    }

    /// What the mirror holds: the Mac's rows above it, the window's first
    /// row (or `tail`), the rows between it and the screen, the most
    /// history rows any replay carried, and the screen's probe.
    var state: String {
        let window = session.historyWindowStart.map(String.init) ?? "tail"
        return "omitted=\(session.historyRowsOmitted) window=\(window) skipped=\(session.historyRowsSkipped) "
            + "fetches=\(daemon.attachCount) down=\(daemon.windowStepsDown) maxHeld=\(daemon.maxHeldRows) of=\(daemon.historyRows) "
            // What the screen did with the reader's place (`TerminalHistoryWindowProbe`).
            + TerminalHistoryWindowProbe.shared.caption
    }
}

/// The fake Mac: one terminal with `historyRows` numbered history rows and
/// a numbered screen, served as cmux-tui serves a windowed viewer.
final class HistoryWindowDaemon: @unchecked Sendable {
    let historyRows: Int
    private let lock = NSLock()
    private var nextChannel: UInt32 = 0
    private var attaches = 0
    private var held = 0
    /// The terminal's grid: the last size an attach or `resize-surface` gave it.
    private var grid = (columns: 80, rows: 40)

    var attachCount: Int { lock.withLock { attaches } }
    var maxHeldRows: Int { lock.withLock { held } }
    /// Window fetches whose first row is nearer the screen than the window
    /// asked for before: the reader coming down moved the window.
    var windowStepsDown: Int { lock.withLock { stepsDown } }
    /// The first row of the last window asked for (`replay_history_start`).
    private var lastWindowStart: Int?
    private var stepsDown = 0

    init(historyRows: Int) {
        self.historyRows = historyRows
    }

    /// A new daemon channel (an attach or an input lane); each request is
    /// answered, and its events sent, on the channel it came on.
    func openChannel() -> FloodChannel {
        let id = lock.withLock { () -> UInt32 in
            nextChannel += 1
            return nextChannel
        }
        let channel = FloodChannel(id: id)
        channel.onSend = { [weak self, weak channel] line in self?.request(line, on: channel) }
        return channel
    }

    static func line(_ row: Int) -> String {
        String(format: "\u{1B}[32m%06ld\u{1B}[0m history row %ld\r\n", row, row)
    }

    private static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The Mac's screen at `rows`: the rows after its history, then a prompt.
    private func screen(rows: Int) -> String {
        var text = ""
        for row in historyRows..<(historyRows + max(1, rows) - 1) { text += Self.line(row) }
        return text + "$ "
    }

    private func request(_ line: Data, on channel: FloodChannel?) {
        guard let channel, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return }
        func reply(_ data: [String: Any] = [:]) -> Data { Self.encode(["id": id, "ok": true, "data": data]) }
        switch cmd {
        case "identify":
            channel.push([reply(["capabilities": ["attach-replay-history-rows-v1", "attach-replay-history-window-v1"]])])
        case "attach-surface":
            let (cols, screenRows): (Int, Int) = lock.withLock {
                if let cols = object["cols"] as? Int, let rows = object["rows"] as? Int, cols > 0, rows > 0 {
                    grid = (cols, rows)
                }
                return grid
            }
            var state: [String: Any] = ["event": "vt-state", "surface": 1, "cols": cols, "rows": screenRows]
            let rows: Range<Int>
            if let allowance = object["replay_history_rows"] as? Int, let asked = object["replay_history_start"] as? Int {
                let size = min(max(allowance, 1), 10_000)
                let start = min(max(0, asked), historyRows)
                let skipped = max(0, historyRows - (start + size))
                state["history_rows_omitted"] = start
                if skipped < size {
                    rows = start..<historyRows
                } else {
                    state["history_rows_skipped"] = skipped
                    rows = start..<(start + size)
                }
            } else if let allowance = object["replay_history_rows"] as? Int {
                let kept = min(historyRows, max(0, allowance))
                state["history_rows_omitted"] = historyRows - kept
                rows = (historyRows - kept)..<historyRows
            } else {
                rows = 0..<historyRows
            }
            var text = ""
            text.reserveCapacity((rows.count + screenRows) * 40)
            for row in rows { text += Self.line(row) }
            text += screen(rows: screenRows)
            state["data"] = Data(text.utf8).base64EncodedString()
            lock.withLock {
                attaches += 1
                held = max(held, rows.count)
                if let start = object["replay_history_start"] as? Int {
                    if let last = lastWindowStart, start > last { stepsDown += 1 }
                    lastWindowStart = start
                }
            }
            NSLog("[history-window-demo] attach %ldx%ld rows=%@ start=%@ held=%ld", cols, screenRows,
                  String(describing: object["replay_history_rows"] ?? "all"),
                  String(describing: object["replay_history_start"] ?? "-"), rows.count)
            channel.push([Self.encode(state), reply(["lease": "l1"])])
        case "resize-surface":
            // As cmux-tui does for a viewer that declared the window: a new
            // grid comes with a `resized` replay of the screen, naming the
            // history rows it left out.
            let cols = object["cols"] as? Int ?? 0
            let rows = object["rows"] as? Int ?? 0
            let changed: Bool = lock.withLock {
                guard cols > 0, rows > 0, cols != grid.columns || rows != grid.rows else { return false }
                grid = (cols, rows)
                return true
            }
            channel.push([reply()])
            if changed {
                NSLog("[history-window-demo] resized %ldx%ld", cols, rows)
                channel.push([Self.encode(["event": "resized", "surface": 1, "cols": cols, "rows": rows,
                                        "history_rows_omitted": historyRows,
                                        "replay": Data(("\u{1B}c" + screen(rows: rows)).utf8).base64EncodedString()])])
            }
        default:
            channel.push([reply()])
        }
    }
}
#endif
