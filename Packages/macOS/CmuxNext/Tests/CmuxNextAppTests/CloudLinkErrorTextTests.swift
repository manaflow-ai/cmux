@testable import CmuxNextApp
@testable import CmuxNextCloud
import Darwin
import Foundation
import Testing

/// A Cloud link failure reads as what failed and the next step. Before, the
/// app showed "(unsupported)" or "(directory is open to others)" and printed
/// `CloudLinkError` as a Swift dump; now each case has a description and a
/// localized message.
@MainActor
struct CloudLinkErrorTextTests {
    @Test(arguments: [
        CloudLinkError.disconnected(reason: "eof"), .revoked(reason: "gone"), .helperNotRunning(reason: "no"),
        .unsafeSocket("socket has another owner"), .openDirectory(path: "/tmp/a b", parent: false),
        .invalidAnswer("not a carrier"), .notUp(state: "starting"), .failed(code: "cmux.cloud.x", message: ""), .unsupported,
    ])
    func everyLinkErrorHasADescriptionWithANextStep(error: CloudLinkError) {
        #expect(error.localizedDescription == error.description)
        #expect(!error.description.contains("CloudLinkError"), "\(error.description)")
        #expect(error.description.contains("Connect"), "\(error.description)")
        #expect(CloudAppLinks.endedMessage(error).contains("Connect"), "\(CloudAppLinks.endedMessage(error))")
    }

    @Test func unsupportedSaysToUpdateCmux() {
        #expect(CloudAppLinks.endedMessage(CloudLinkError.unsupported) == CloudStrings.linkUnsupported)
        #expect(CloudLinkError.unsupported.description.contains("Update cmux"))
    }

    @Test func aFailedCheckShowsNoEnglishDetail() {
        #expect(CloudAppLinks.endedMessage(CloudLinkError.unsafeSocket("socket has another owner")) == CloudStrings.linkCheckFailed)
        #expect(CloudAppLinks.endedMessage(CloudLinkError.invalidAnswer("not a carrier")) == CloudStrings.linkCheckFailed)
        #expect(CloudAppLinks.endedMessage(CloudLinkError.notUp(state: "starting")) == CloudStrings.linkNotReady("starting"))
    }

    @Test func anOpenDirectoryNamesTheQuotedChmodThatFixesIt() {
        #expect(CloudLinkError.chmodFix(path: "/tmp/a b", parent: false) == "chmod 700 '/tmp/a b'")
        #expect(CloudLinkError.chmodFix(path: "/Users/me", parent: true) == "chmod go-w /Users/me")
        #expect(CloudLinkError.shellQuoted("it's") == "'it'\\''s'")
        #expect(CloudAppLinks.endedMessage(CloudLinkError.openDirectory(path: "/tmp/a b", parent: false))
            == CloudStrings.linkOpenDirectory("/tmp/a b", fix: "chmod 700 '/tmp/a b'"))
        #expect(CloudLinkError.openDirectory(path: "/tmp/a b", parent: false).localizedDescription.contains("`chmod 700 '/tmp/a b'`"))
    }

    @Test func theSocketPolicyReportsAnOpenDirectoryWithItsPath() throws {
        let directory = "/private/tmp/cxl-\(UUID().uuidString.prefix(8).lowercased())"
        #expect(mkdir(directory, 0o755) == 0)
        defer { rmdir(directory) }
        #expect(chmod(directory, 0o755) == 0)
        #expect(throws: CloudLinkError.openDirectory(path: directory, parent: false)) {
            try CloudLinkSocketPolicy.check(directory + "/cmux-link-0123456789ab.sock")
        }
    }

    @Test func aCarrierThatIsNotUpIsNamedByItsState() async {
        let resolver = CloudConnectOpResolver(run: { _, _, _, _ in Data(#"{"machine":"m1","state":"starting"}"#.utf8) }, check: { _ in })
        await #expect(throws: CloudLinkError.notUp(state: "starting")) {
            _ = try await resolver.open(CloudLinkKey(machine: "m1"), intent: "i", origin: .script)
        }
    }

    @Test func anAppOpErrorReadsAsItsMessageElseItsCode() {
        #expect(CloudAppOpError(code: "cmux.cloud.link_down", message: "The link ended.").localizedDescription == "The link ended.")
        #expect(CloudAppOpError(code: "cmux.cloud.link_down", message: "").localizedDescription == "cmux.cloud.link_down")
    }
}
