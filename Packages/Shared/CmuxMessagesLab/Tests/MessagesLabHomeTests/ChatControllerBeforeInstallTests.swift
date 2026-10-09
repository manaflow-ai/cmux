import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program (plans/cmux-next/crash-elimination.md): the pane controller's store and
/// window view were implicitly unwrapped and trapped when read before `install`. Read
/// early, they are an empty conversation and its window view.
@MainActor @Suite struct ChatControllerBeforeInstallTests {
    @Test func storeAndWindowViewReadBeforeInstallAreEmpty() {
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 628, height: 900)), wake: NoWake())
        #expect(controller.store.state.conversation.messages.isEmpty)
        #expect(controller.demo.lastTextRow(mine: false) == nil)
    }
}
