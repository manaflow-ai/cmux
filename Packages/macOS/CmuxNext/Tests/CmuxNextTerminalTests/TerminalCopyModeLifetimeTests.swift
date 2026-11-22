import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// Copy mode keeps an unowned back-reference to its surface view
/// (crash-allowlist.json: "owned child, nested lifetime"); it ends with it.
@MainActor @Suite struct TerminalCopyModeLifetimeTests {
    @Test func copyModeEndsWithItsSurfaceView() {
        weak var weakView: TerminalSurfaceView?
        weak var weakCopyMode: TerminalCopyMode?
        do {
            let (_, continuation) = AsyncStream<TerminalOutgoing>.makeStream()
            let view = TerminalSurfaceView(io: GHOSTTY_SURFACE_IO_MANUAL, input: TerminalInputSink(continuation: continuation), session: nil)
            weakView = view
            weakCopyMode = view.copyMode
        }
        #expect(weakView == nil)
        #expect(weakCopyMode == nil)
    }
}
