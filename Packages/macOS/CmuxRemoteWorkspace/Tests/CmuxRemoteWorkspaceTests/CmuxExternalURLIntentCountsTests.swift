import Foundation
import Testing
@testable import CmuxRemoteWorkspace

private let scheme = "cmux-test"
private let supported: Set<String> = [scheme]

@Suite("CmuxExternalURLIntentCounts")
struct CmuxExternalURLIntentCountsTests {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("invalid test URL: \(string)")
        }
        return url
    }

    @Test("no recognized intent counts as zero and no multiple-links error")
    func emptyClassification() {
        let counts = CmuxExternalURLIntentCounts.classify(
            urls: [url("https://example.com/page")],
            supportedSchemes: supported
        )
        #expect(counts.total == 0)
        #expect(counts.multipleLinksError == nil)
    }

    @Test("a single SSH link is one SSH intent with no multiple-links error")
    func singleSSHIntent() {
        let counts = CmuxExternalURLIntentCounts.classify(
            urls: [url("\(scheme)://ssh/example.com")],
            supportedSchemes: supported
        )
        #expect(counts.ssh == 1)
        #expect(counts.total == 1)
        #expect(counts.multipleLinksError == nil)
    }

    @Test("multiple all-SSH intents select the SSH multiple-links error")
    func multipleSSHSelectsSSHError() {
        let counts = CmuxExternalURLIntentCounts(ssh: 2, navigation: 0, text: 0)
        #expect(counts.total == 2)
        #expect(counts.multipleLinksError == .ssh)
    }

    @Test("multiple mixed intents select the text multiple-links error")
    func mixedSelectsTextError() {
        let counts = CmuxExternalURLIntentCounts(ssh: 1, navigation: 0, text: 1)
        #expect(counts.total == 2)
        #expect(counts.multipleLinksError == .text)
    }

    @Test("multiple SSH with navigation present is not the SSH-only error")
    func sshWithNavigationIsTextError() {
        let counts = CmuxExternalURLIntentCounts(ssh: 2, navigation: 1, text: 0)
        #expect(counts.multipleLinksError == .text)
    }

    @Test("a single non-SSH-only intent total never yields a multiple-links error")
    func singleNeverErrors() {
        let counts = CmuxExternalURLIntentCounts(ssh: 1, navigation: 0, text: 0)
        #expect(counts.total == 1)
        #expect(counts.multipleLinksError == nil)
    }
}
