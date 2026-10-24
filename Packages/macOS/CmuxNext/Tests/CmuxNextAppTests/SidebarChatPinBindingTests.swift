import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
@testable import CmuxNextApp
import Foundation
import Testing

/// Pin/Unpin Chat (`sidebar.chat.togglePin`) has a handler whether or not this Mac has a local acpmux: it was
/// bound only when the Chats feed started, so a launch without one (the every-action sweep's, macOS 27) answered
/// `not_bound: sidebar.chat.togglePin has no handler in this build`.
@MainActor @Suite(.serialized)
struct SidebarChatPinBindingTests {
    @Test func pinChatIsBoundWithTheAppsActions() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.isBound(SidebarChatHistoryFeed.togglePinAction))
    }
}
