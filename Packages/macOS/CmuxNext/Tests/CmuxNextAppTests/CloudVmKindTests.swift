@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The attach-endpoint's `vmKind` (the Cloud API's answer, for the signed-in caller, whether a
/// machine is its own personal VM) decides the link's `--vm-kind owner`, and with it the VM
/// boundary for that machine's remote chains (acpmux `hub/vm_boundary.rs`). Only the exact
/// string "owner" opts out of the sandbox; a missing, null, other or malformed value keeps it,
/// and never fails the attach.
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

    @Test func anOlderServerOrAMalformedValueKeepsTheSandboxAndStillAttaches() throws {
        let older = try endpoint(nil)
        #expect(older.vmKind == nil)
        #expect(CloudMachineLink.vmKindArguments(older).isEmpty)
        for malformed in ["1", "true", #"{"kind":"owner"}"#, #"["owner"]"#] {
            let decoded = try endpoint(malformed)
            #expect(decoded.vmKind == nil, "\(malformed)")
            #expect(decoded.route == "ws://10.9.0.2:1337/v1/link")
            #expect(CloudMachineLink.vmKindArguments(decoded).isEmpty, "\(malformed)")
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

    /// A Cloud machine whose daemon cannot take `vm_kind` would allow on the VM's own `owner`
    /// record alone, so the app refuses that start unless the link said the caller owns it.
    @Test func aCloudStartThroughAnOlderDaemonNeedsTheOwnerAnswer() {
        #expect(!AgentTabRemoteStart.mayStart(cloud: true, callerOwnsVM: false, servesVMKind: false))
        #expect(AgentTabRemoteStart.mayStart(cloud: true, callerOwnsVM: true, servesVMKind: false))
        #expect(AgentTabRemoteStart.mayStart(cloud: true, callerOwnsVM: false, servesVMKind: true))
        #expect(AgentTabRemoteStart.mayStart(cloud: false, callerOwnsVM: false, servesVMKind: false))
    }
}
