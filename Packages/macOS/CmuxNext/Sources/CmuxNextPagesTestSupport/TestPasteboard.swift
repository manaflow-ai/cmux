import AppKit
import Foundation

/// Whether this test process reaches a pasteboard server.
///
/// A test step on a Mac with no login session often reaches none: there each pasteboard write fails
/// and each read returns nil, also for a pasteboard with its own name. A test that writes a pasteboard
/// and reads it back names ``isReachable`` as its condition, so such a step says that the test was
/// skipped and why, and does not fail. A test of code that needs no pasteboard stays out of it and runs
/// everywhere: keep the part that needs the pasteboard in a test of its own.
///
/// ```swift
/// @Test(.enabled(if: TestPasteboard.isReachable, "needs a pasteboard server")) func copyWritesTheLink() { ... }
/// ```
public nonisolated enum TestPasteboard {
    /// The answer of one probe, made once in a test process: a write to a pasteboard of its own and a
    /// read of it back.
    public static let isReachable: Bool = {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-test-pasteboard-probe-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        return board.setString("probe", forType: .string) && board.string(forType: .string) == "probe"
    }()
}
