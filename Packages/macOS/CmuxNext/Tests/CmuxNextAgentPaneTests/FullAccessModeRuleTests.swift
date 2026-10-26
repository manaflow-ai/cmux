@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The app and acpmux name the same modes full access: the app's markers are the ones in
/// cmux-tui/spec/full-access-modes.json, folded the same way.
struct FullAccessModeRuleTests {
    @Test func theMarkersMatchTheSharedSpec() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/full-access-modes.json"))
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(spec["markers"] as? [String] == AgentPaneModeConfirmation.fullAccessMarkers)
        #expect(spec["allowedModes"] as? [String] == AgentPaneModeConfirmation.allowedModes)
    }

    /// Permission modes are an allowlist that fails closed: a mode no one reviewed counts as full access.
    @Test func anUnknownModeIsFullAccess() {
        for id in ["default", "acceptEdits", "plan", "dontAsk", "auto", "ask", "read-only", "Read Only", "agent", "full-auto"] {
            #expect(!AgentPaneModeConfirmation.isFullAccessMode(id), "\(id)")
            #expect(!AgentPaneModeConfirmation.mode(id).skipsApprovals, "\(id)")
        }
        for id in ["bypassPermissions", "agent-full-access", "yolo", "turbo", "build", "normal"] {
            #expect(AgentPaneModeConfirmation.isFullAccessMode(id), "\(id)")
            #expect(AgentPaneModeConfirmation.mode(id).skipsApprovals, "\(id)")
        }
        // Another option's value is judged by its markers only.
        #expect(!AgentPaneModeConfirmation.option(id: "sandbox", value: "turbo").skipsApprovals)
        #expect(AgentPaneModeConfirmation.option(id: "sandbox", value: "danger-full-access").skipsApprovals)
    }

    @Test func idsAreFoldedBeforeMatching() {
        for id in ["bypassPermissions", "agent-full-access", "danger-full-access", "yolo", "auto-approve",
                   "Auto Approve", "dangerously_skip_permissions", "skip-permissions"] {
            #expect(AgentPaneModeConfirmation.isFullAccess(id), "\(id)")
        }
        for id in ["default", "agent", "ask", "read-only", "plan", "acceptEdits", "full-auto", "fullscreen", "full-context"] {
            #expect(!AgentPaneModeConfirmation.isFullAccess(id), "\(id)")
        }
    }
}
