import Testing

@testable import CmuxMobileShellUI

@Suite("VoiceToolCatalog")
struct VoiceToolPermissionTests {
    @Test("read tools classify as read")
    func readTools() {
        for name in [
            "list_workspaces", "read_workspace", "read_agent_messages",
            "read_notifications", "list_computers", "read_workspace_changes",
            "list_memories",
        ] {
            #expect(VoiceToolCatalog.permission(forTool: name) == .read)
        }
    }

    @Test("acting tools classify as act")
    func actTools() {
        for name in [
            "send_prompt", "answer_agent_question", "interrupt_agent",
            "open_workspace", "create_workspace", "create_terminal",
            "rename_workspace", "set_workspace_pinned", "set_workspace_unread",
            "mark_all_notifications_read", "create_task", "switch_computer",
            "set_workspace_description", "set_workspace_color",
            "mark_notification_read", "open_notification",
            "remember", "forget_memory",
        ] {
            #expect(VoiceToolCatalog.permission(forTool: name) == .act)
        }
    }

    @Test("terminal typing and workspace closing are destructive; unknown tools default to act")
    func destructiveAndUnknown() {
        #expect(VoiceToolCatalog.permission(forTool: "close_workspace") == .destructive)
        #expect(VoiceToolCatalog.permission(forTool: "type_in_terminal") == .destructive)
        #expect(VoiceToolCatalog.permission(forTool: "future_tool") == .act)
    }
}
