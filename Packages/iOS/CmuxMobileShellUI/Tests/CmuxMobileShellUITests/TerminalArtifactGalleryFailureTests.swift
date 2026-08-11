#if os(iOS)
import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite
struct TerminalArtifactGalleryFailureTests {
    @Test
    func preservesSpecificFailureMeaning() {
        #expect(TerminalArtifactGalleryFailure(error: ChatArtifactError.macUnreachable) == .macUnreachable)
        #expect(TerminalArtifactGalleryFailure(error: ChatArtifactError.sessionNotFound) == .sessionMissing)
        #expect(TerminalArtifactGalleryFailure(error: ChatArtifactError.fileNotFound) != .loadFailed)
        #expect(TerminalArtifactGalleryFailure(error: CocoaError(.fileReadUnknown)) == .loadFailed)
    }
}
#endif
