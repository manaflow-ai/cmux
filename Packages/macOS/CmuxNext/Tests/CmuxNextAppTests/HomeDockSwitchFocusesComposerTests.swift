import AppKit
@testable import CmuxNextHome
import Testing

/// Lawrence 2026-10-20: "after switching a chat in imessage ui we need to be visibly focused to the
/// new chat's input box area".
///
/// The docked Home opens a conversation through `HomeDockSwitchView.switchTo(_:selection:)` (the
/// Channels page's `cmux.host.home.switchView`, the Home/Channels entries). A switch to the view
/// already shown, with a conversation, opens that conversation and must hand the keyboard to its
/// message box, as a switch to the other view does.
@MainActor @Suite struct HomeDockSwitchFocusesComposerTests {
    /// Records what the dock asked of its two views, in order.
    final class RecordingDock: HomeDockSwitchView {
        enum Call: Equatable { case open(String), focus(HomeDockMode) }
        var calls: [Call] = []

        override func makeContent(for mode: HomeDockMode) -> NSView? { NSView() }
        override func open(_ selection: HomeDockSelection, in mode: HomeDockMode) { calls.append(.open(selection.conversation)) }
        override func focusContent(_ mode: HomeDockMode) { calls.append(.focus(mode)) }
    }

    @Test func switchingToTheShownViewWithAConversationFocusesItsMessageBox() async {
        let dock = RecordingDock(mode: .messages)
        dock.switchTo(.messages, selection: HomeDockSelection(conversation: "conv_dock_focus_b"))
        await dock.settled()
        #expect(dock.calls == [.open("conv_dock_focus_b"), .focus(.messages)])
    }

    @Test func switchingToTheShownViewWithoutAConversationLeavesTheKeyboard() async {
        let dock = RecordingDock(mode: .messages)
        dock.switchTo(.messages)
        await dock.settled()
        #expect(dock.calls.isEmpty)
    }
}
