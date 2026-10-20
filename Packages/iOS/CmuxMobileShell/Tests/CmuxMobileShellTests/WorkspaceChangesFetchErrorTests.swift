import CmuxMobileRPC
@testable import CmuxMobileShell
import Testing

@Suite
struct WorkspaceChangesFetchErrorTests {
    @Test
    func notARepoCodeMapsToNotARepository() {
        let mapped = MobileShellComposite.workspaceChangesFetchError(
            .rpcError("not_a_repo", "Workspace directory is not a Git repository")
        )
        #expect(mapped == .notARepository)
    }

    @Test
    func otherRPCCodesMapToTransport() {
        #expect(MobileShellComposite.workspaceChangesFetchError(.rpcError("not_found", "missing")) == .transport)
        #expect(MobileShellComposite.workspaceChangesFetchError(.rpcError(nil, "unknown")) == .transport)
        #expect(MobileShellComposite.workspaceChangesFetchError(.requestTimedOut) == .transport)
    }
}
