import AppKit
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Issue #16184 (cx-6so.56): about one new split in eight showed no first prompt. In classic the
/// mirror parsed the daemon's first output at the view's grid, then resized to the daemon's grid,
/// and Ghostty cleared the OSC 133 prompt on that resize with no shell behind the mirror to draw it
/// again (#16214). A new pane's mirror here gets its first prompt in each order the daemon can
/// send it, at grids that differ from the view's, and must keep it.
@MainActor @Suite(.serialized) struct SplitFirstPromptMirrorTests {
    enum Order: CaseIterable {
        /// The daemon's grid, then the shell's first prompt.
        case gridFirst
        /// The prompt reaches the mirror before the daemon's grid does.
        case outputFirst
        /// An attach replay of the prompt, then the grid.
        case replayFirst
    }

    static let prompt = "\u{1b}]133;A\u{07}prompt$ \u{1b}]133;B\u{07}"

    /// The viewport text once the events before `sentinel` are applied, or nil after 5 s.
    static func shown(_ session: TerminalSession, through sentinel: String) async throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let text = session.surfaceView.viewportText(), text.contains(sentinel) { return text }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func everyNewPanesMirrorKeepsItsFirstPrompt() async throws {
        _ = NSApplication.shared
        var lost: [String] = []
        for i in 0..<60 {
            let order = Order.allCases[i % Order.allCases.count]
            let grid = (columns: 70 + i % 11, rows: 22 + i % 5)
            let io = ScriptedTerminalIO()
            let session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            session.view.layoutSubtreeIfNeeded()
            let prompt = Data(Self.prompt.utf8)
            switch order {
            case .gridFirst:
                io.send(.resize(cols: grid.columns, rows: grid.rows))
                io.send(.output(prompt))
            case .outputFirst:
                io.send(.output(prompt))
                io.send(.resize(cols: grid.columns, rows: grid.rows))
            case .replayFirst:
                io.send(.replay(prompt))
                io.send(.resize(cols: grid.columns, rows: grid.rows))
            }
            // A mark further down, after the grid, shows the mirror has applied everything above.
            let sentinel = "sentinel-\(i)"
            io.send(.output(Data("\u{1b}7\u{1b}[\(grid.rows);1H\(sentinel)\u{1b}8".utf8)))
            let text = try await Self.shown(session, through: sentinel)
            if text?.contains("prompt$") != true { lost.append("\(i) \(order) \(grid): \(text.map { String($0.prefix(80)) } ?? "never applied")") }
            io.finish()
            window.close()
        }
        #expect(lost.isEmpty, "\(lost.count) of 60 new panes lost their first prompt: \(lost)")
    }
}
