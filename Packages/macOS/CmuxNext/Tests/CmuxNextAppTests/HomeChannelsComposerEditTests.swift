import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Testing

/// The Channels composer's right-click menu (POLISH.md right-click contract): its Cut, Copy, Paste
/// and Paste as Plain Text reach the app as `cmux.app.edit {command}` and run as the page view's own
/// responder action, only on the person's click or key; page script alone never pastes.
@MainActor
struct HomeChannelsComposerEditTests {
    @Test func theChannelsPageEditsItsFieldOnlyOnThePersonsGesture() async throws {
        #expect(PageDescriptor.homeChannels.admits(PageNativeOp.edit))
        var ran: [AgentPaneEditCommand] = []
        let route = PageFactory.homeChannelsEditRoute { ran.append($0) }
        #expect(PageNativeOp.edit.hasPrefix(route.prefix))

        let clicked = PageCallContext(page: "cmux.home-channels", userGesture: true)
        _ = try await route.provider.call(PageNativeOp.edit, params: ["command": "paste"], context: clicked)
        _ = try await route.provider.call(PageNativeOp.edit, params: ["command": "pasteAsPlainText"], context: clicked)
        #expect(ran == [.paste, .pasteAsPlainText])

        // Page script with no click or key behind it: refused, the field untouched.
        let script = PageCallContext(page: "cmux.home-channels")
        await #expect(throws: PageError.self) {
            try await route.provider.call(PageNativeOp.edit, params: ["command": "paste"], context: script)
        }
        await #expect(throws: PageError.self) {
            try await route.provider.call(PageNativeOp.edit, params: ["command": "selectAll"], context: clicked)
        }
        #expect(ran == [.paste, .pasteAsPlainText])
    }
}
