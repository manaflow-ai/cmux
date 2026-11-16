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

    /// The person's mode pick goes only with the owner word, and only to a daemon that takes it: a
    /// teammate's or a team machine's start never names a mode (the daemon would ignore it anyway).
    @Test func aStartSendsTheModePickOnlyWithTheOwnerWord() {
        let params = { (owns: Bool, servesKind: Bool, servesMode: Bool) in
            AgentSessionAttachClient.startParams(cwd: "/w", harness: "claude", homeConfirmed: false, personKey: nil,
                                                 servesKeyedReason: false, callerOwnsVM: owns, servesVMKind: servesKind,
                                                 startMode: "bypassPermissions", servesStartMode: servesMode)
        }
        #expect(params(true, true, true)["mode"] as? String == "bypassPermissions")
        #expect(params(true, true, false)["mode"] == nil)
        #expect(params(true, false, true)["mode"] == nil)
        #expect(params(false, true, true)["mode"] == nil)
        #expect(DaemonCapability.agentSessionStartMode.rawValue == "agent-session-start-mode-v1")
    }

    @Test func aNoFolderStartOmitsCwdOnlyAsAnAbsentParameter() {
        let params = AgentSessionAttachClient.startParams(cwd: nil, harness: nil, homeConfirmed: false, personKey: nil,
                                                           servesKeyedReason: false, callerOwnsVM: true, servesVMKind: true)
        #expect(params["cwd"] == nil)
        #expect(params["vm_kind"] as? String == "owner")
        #expect(DaemonCapability.agentSessionStartNoCwd.rawValue == "agent-session-start-no-cwd-v1")
    }
}
