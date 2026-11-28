#if os(iOS)
import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite
struct TerminalArtifactGalleryFailureTests {
    @Test
    func preservesSpecificFailureMeaning() {
        #expect(TerminalArtifactGalleryFailure(error: ChatArtifactError.macUnreachable).error == .macUnreachable)
        #expect(TerminalArtifactGalleryFailure(error: ChatArtifactError.sessionNotFound).error == .sessionNotFound)
        #expect(TerminalArtifactGalleryFailure(error: ChatArtifactError.fileNotFound).error == .fileNotFound)
        #expect(TerminalArtifactGalleryFailure(error: CocoaError(.fileReadUnknown)).error == .loadFailed)
    }
}
#endif
