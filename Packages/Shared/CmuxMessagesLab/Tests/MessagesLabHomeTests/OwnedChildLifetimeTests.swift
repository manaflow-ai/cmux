import AppKit
import Testing
@testable import MessagesLabHome

/// Helpers that keep an unowned back-reference to their owner
/// (crash-allowlist.json: "owned child, nested lifetime") end with it.
@MainActor @Suite struct OwnedChildLifetimeTests {
    @Test func transcriptSelectionEndsWithItsController() {
        weak var weakController: ChatController?
        weak var weakSelection: TranscriptSelection?
        do {
            let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 628, height: 900)), wake: NoWake())
            weakController = controller
            weakSelection = controller.selection
        }
        #expect(weakController == nil)
        #expect(weakSelection == nil)
    }

    @Test func scrollPhysicsEndsWithItsScrollView() {
        weak var weakView: UIScrollView?
        weak var weakPhysics: ScrollPhysics?
        autoreleasepool {
            let view = UIScrollView(frame: .zero)
            weakView = view
            weakPhysics = view.physics
        }
        #expect(weakView == nil)
        #expect(weakPhysics == nil)
    }
}
