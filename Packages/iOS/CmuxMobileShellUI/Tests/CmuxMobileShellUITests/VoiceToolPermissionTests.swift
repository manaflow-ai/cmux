import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite("VoiceToolPermission")
struct VoiceToolPermissionTests {
    @Test("read tools classify as read")
    func readTools() {
        for name in [
            "list_workspaces", "read_workspace", "read_agent_messages",
            "wait_for_agent", "wait", "read_notifications", "list_computers", "read_workspace_changes",
            "list_memories", "search_task_directories",
        ] {
            #expect(VoiceToolPermission(toolNamed: name) == .read)
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
            #expect(VoiceToolPermission(toolNamed: name) == .act)
        }
    }

    @Test("terminal typing and workspace closing are destructive; unknown tools default to act")
    func destructiveAndUnknown() {
        #expect(VoiceToolPermission(toolNamed: "close_workspace") == .destructive)
        #expect(VoiceToolPermission(toolNamed: "type_in_terminal") == .destructive)
        #expect(VoiceToolPermission(toolNamed: "future_tool") == .act)
    }

    @Test("wait bounds its timeout and the catalog exposes both wait tools")
    func waitTools() {
        #expect(VoiceOrchestratorToolExecutor.boundedWaitSeconds(nil) == 45)
        #expect(VoiceOrchestratorToolExecutor.boundedWaitSeconds(0) == 1)
        #expect(VoiceOrchestratorToolExecutor.boundedWaitSeconds(240) == 120)
        #expect(
            Set(VoiceOrchestratorToolExecutor.tools.map(\.name)).isSuperset(
                of: ["wait_for_agent", "wait"]
            )
        )
    }
}
