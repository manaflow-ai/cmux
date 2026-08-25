#if os(iOS)
import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite
struct MarkdownSurfaceModelFailureTests {
    @Test
    @MainActor
    func unknownErrorKeepsItsCodeInsteadOfBlamingConnectivity() {
        #expect(MarkdownSurfaceModel.failure(for: ChatArtifactError.unknown(code: "artifact_rev_gone")) == .loadFailed(code: "artifact_rev_gone"))
        #expect(MarkdownSurfaceModel.failure(for: ChatArtifactError.unknown(code: nil)) == .loadFailed(code: nil))
    }
}
#endif
