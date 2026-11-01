@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The attach-endpoint's `vmKind` (the Cloud API's answer, for the signed-in caller, whether a
/// machine is its own personal VM) decides the link's `--vm-kind owner`, and with it the VM
/// boundary for that machine's remote chains (acpmux `hub/vm_boundary.rs`). Only the exact
/// string "owner" opts out of the sandbox; a missing, null or other value keeps it, and a value
/// of another type fails the attach (never owner).
struct CloudVmKindTests {
    private func endpoint(_ vmKind: String?) throws -> CloudAttachEndpoint {
        let field = vmKind.map { #","vmKind":\#($0)"# } ?? ""
        let body = #"{"transport":"cmux-remote","route":"ws://10.9.0.2:1337/v1/link","session":"s","trustedCarrier":true\#(field)}"#
        return try JSONDecoder().decode(CloudAttachEndpoint.self, from: Data(body.utf8))
    }

    @Test func onlyOwnerStartsTheLinkAtTheVMBoundary() throws {
        let owner = try endpoint(#""owner""#)
        #expect(owner.vmKind == "owner")
        #expect(owner.callerOwnsVM)
        #expect(CloudMachineLink.vmKindArguments(owner) == ["--vm-kind", "owner"])
        for kind in [#""team""#, "null", #""Owner""#, #""""#] {
            let other = try endpoint(kind)
            #expect(!other.callerOwnsVM, "\(kind)")
            #expect(CloudMachineLink.vmKindArguments(other).isEmpty, "\(kind)")
        }
    }

    @Test func anOlderServerKeepsTheSandboxAndAMalformedValueIsNeverOwner() throws {
        let older = try endpoint(nil)
        #expect(older.vmKind == nil)
        #expect(CloudMachineLink.vmKindArguments(older).isEmpty)
        for malformed in ["1", "true", #"{"kind":"owner"}"#, #"["owner"]"#] {
            #expect(throws: (any Error).self, "\(malformed)") { _ = try endpoint(malformed) }
        }
    }

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

    @Test func aNoFolderStartOmitsCwdOnlyAsAnAbsentParameter() {
        let params = AgentSessionAttachClient.startParams(cwd: nil, harness: nil, homeConfirmed: false, personKey: nil,
                                                           servesKeyedReason: false, callerOwnsVM: true, servesVMKind: true)
        #expect(params["cwd"] == nil)
        #expect(params["vm_kind"] as? String == "owner")
        #expect(DaemonCapability.agentSessionStartNoCwd.rawValue == "agent-session-start-no-cwd-v1")
    }
}
