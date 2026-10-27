import CmuxNextCloud
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
}
