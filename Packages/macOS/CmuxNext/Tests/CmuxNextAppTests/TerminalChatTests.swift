import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Open Terminal as Chat (`palette.openTerminalChatView`, `cmux agent open-terminal-as-chat`):
/// the focused terminal's Claude Code or Codex session opens as an agent chat tab that resumes
/// the same session over ACP (acpmux adopt). It is a working action, not a greyed-out row.
@MainActor @Suite(.serialized)
struct TerminalChatTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test func openTerminalAsChatIsAWorkingAction() {
        let services = Self.services()
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.openTerminalChatView") == nil)
    }
}
