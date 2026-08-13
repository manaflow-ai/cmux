#if os(iOS)
import Testing

@testable import CmuxMobileShellUI

@Suite
struct WorkspaceChatArtifactLoaderIdentityTests {
    @Test
    func replacingTheChatEventSourceInvalidatesTheCachedLoader() {
        let first = WorkspaceChatArtifactLoaderIdentity(
            sessionID: "session-1",
            supportsArtifacts: true,
            sourceIdentity: "source-1"
        )
        let replacement = WorkspaceChatArtifactLoaderIdentity(
            sessionID: "session-1",
            supportsArtifacts: true,
            sourceIdentity: "source-2"
        )

        #expect(first != replacement)
    }

    @Test
    func unchangedChatEventSourceKeepsTheCachedLoaderIdentityStable() {
        let first = WorkspaceChatArtifactLoaderIdentity(
            sessionID: "session-1",
            supportsArtifacts: true,
            sourceIdentity: "source-1"
        )
        let sameSource = WorkspaceChatArtifactLoaderIdentity(
            sessionID: "session-1",
            supportsArtifacts: true,
            sourceIdentity: "source-1"
        )

        #expect(first == sameSource)
    }
}
#endif
