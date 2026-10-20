import Foundation
import Testing
@testable import CmuxNextHelperSecurity

struct HelperExecutableTrustTests {
    @Test func rejectsAnUnsignedReference() {
        let trust = HelperExecutableTrust(
            expectedTeamIdentifier: nil,
            isDirectRegularFile: { _ in true },
            validatesCode: { _, _ in true }
        )

        #expect(!trust.accepts(URL(fileURLWithPath: "/helper")))
    }

    @Test func acceptsTheExpectedSignedFixtureAndRejectsCrossTeamCodeAndASymlink() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { repository.deleteLastPathComponent() }
        let signed = repository.appendingPathComponent(
            "tests/fixtures/cua-helper-signatures/apple-distribution/cmux Computer Use.app/Contents/MacOS/cmux-cua"
        )
        let trust = HelperExecutableTrust(reference: .teamIdentifier("7WLXT3NR37"))
        #expect(trust.accepts(signed))
        #expect(!trust.accepts(URL(fileURLWithPath: "/bin/ls")))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helper-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: signed)

        #expect(!trust.accepts(link))
    }
}
