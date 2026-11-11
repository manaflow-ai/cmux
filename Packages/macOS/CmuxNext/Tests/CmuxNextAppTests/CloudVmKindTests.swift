@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The link's owner answer (the Cloud API's answer, for the signed-in caller, whether a machine is
/// its own personal VM) decides a start's `vm_kind: "owner"`, and with it the VM boundary for that
/// machine's remote chains (acpmux `hub/vm_boundary.rs`).
struct CloudVmKindTests {
    /// `agent-session-start` sends `vm_kind: "owner"` only on the caller's owner answer and only
    /// to a daemon that takes the param (an older one refuses an unknown param).
    @Test func aStartSendsTheOwnerWordOnlyToADaemonThatTakesIt() {
        let params = { (owns: Bool, serves: Bool) in
            AgentSessionAttachClient.startParams(cwd: "/w", harness: nil, homeConfirmed: false, personKey: nil,
                                                 servesKeyedReason: false, callerOwnsVM: owns, servesVMKind: serves)
        }
        #expect(params(true, true)["vm_kind"] as? String == "owner")
        #expect(params(true, false)["vm_kind"] == nil)
        #expect(params(false, true)["vm_kind"] == nil)
        #expect(params(false, false)["vm_kind"] == nil)
        #expect(DaemonCapability.agentSessionStartVMKind.rawValue == "agent-session-start-vm-kind-v1")
    }

    @Test func aStartSendsTheModelOnlyToARecentDaemon() {
        let old = AgentSessionAttachClient.startParams(cwd: "/w", harness: "codex",
                                                       homeConfirmed: false, personKey: nil,
                                                       servesKeyedReason: false, callerOwnsVM: false,
                                                       servesVMKind: false, model: "m", servesModel: false)
        let recent = AgentSessionAttachClient.startParams(cwd: "/w", harness: "codex",
                                                          homeConfirmed: false, personKey: nil,
                                                          servesKeyedReason: false, callerOwnsVM: false,
                                                          servesVMKind: false, model: "m", servesModel: true)
        #expect(old["model"] == nil)
        #expect(recent["model"] as? String == "m")
        #expect(DaemonCapability.agentSessionStartModel.rawValue == "agent-session-start-model-v1")
    }

    /// A Cloud chat on the person's own machine starts in their `agents.defaultPermissionMode`, as a local new chat does
    /// (unset: full access, acpmux's default), sent only to a daemon that takes it and only for the owner's own VM; a value
    /// acpmux does not know sends nothing, so the start keeps asking.
    @Test func anOwnersStartSendsThePersonsPermissionMode() {
        let params = { (setting: String?, owns: Bool, serves: Bool) in
            AgentSessionAttachClient.startParams(cwd: nil, harness: nil, homeConfirmed: false, personKey: nil, servesKeyedReason: false,
                                                 callerOwnsVM: owns, servesVMKind: true, servesPermissionMode: serves,
                                                 permissionMode: setting)["permission_mode"] as? String
        }
        #expect(params(nil, true, true) == "fullAccess")
        #expect(params("bypassPermissions", true, true) == "fullAccess")
        #expect(params("standard", true, true) == "standard")
        #expect(params("ask", true, true) == "ask")
        #expect(params("anything", true, true) == nil)
        #expect(params("fullAccess", false, true) == nil, "a teammate's or another host's start keeps asking")
        #expect(params("fullAccess", true, false) == nil, "an older daemon refuses an unknown param")
        #expect(DaemonCapability.agentSessionStartPermissionMode.rawValue == "agent-session-start-permission-mode-v1")
    }

    @Test func aNoFolderStartOmitsCwdOnlyAsAnAbsentParameter() {
        let params = AgentSessionAttachClient.startParams(cwd: nil, harness: nil, homeConfirmed: false, personKey: nil,
                                                           servesKeyedReason: false, callerOwnsVM: true, servesVMKind: true)
        #expect(params["cwd"] == nil)
        #expect(params["vm_kind"] as? String == "owner")
        #expect(DaemonCapability.agentSessionStartNoCwd.rawValue == "agent-session-start-no-cwd-v1")
    }
}
