import Testing
@testable import CMUXMobileCore

/// Pins the mobile `workspace.action` allow-list to the pin/rename/read-state
/// subset, including the trim/lowercase/hyphen normalization the gate applies.
@Suite struct MobileWorkspaceActionTests {
    @Test func allowsOnlyPinNameAndReadStateActions() {
        for action in [
            "pin", "unpin", "rename", "mark_read", "mark_unread",
            "PIN", "UnPin", "RENAME", "MARK_READ", "Mark_Unread",
        ] {
            #expect(
                MobileWorkspaceAction.isMobileAllowed(action),
                "mobile workspace.action '\(action)' should be allowed"
            )
        }
        for action in [
            "move_up", "move-down", "move_top",
            "close_others", "close_above", "close_below",
            "set_color", "clear_color", "set_description", "clear_description",
            "clear_name", "close", "self_destruct", "",
        ] {
            #expect(
                !MobileWorkspaceAction.isMobileAllowed(action),
                "mobile workspace.action '\(action)' must be rejected"
            )
        }
        #expect(!MobileWorkspaceAction.isMobileAllowed(nil))
    }

    @Test func normalizesHyphensAndWhitespaceWhenMatching() {
        #expect(MobileWorkspaceAction(rawMobileAction: "  mark-read  ") == .markRead)
        #expect(MobileWorkspaceAction(rawMobileAction: "UNPIN") == .unpin)
        #expect(MobileWorkspaceAction(rawMobileAction: "pin") == .pin)
        #expect(MobileWorkspaceAction(rawMobileAction: nil) == nil)
        #expect(MobileWorkspaceAction(rawMobileAction: "   ") == nil)
    }
}
