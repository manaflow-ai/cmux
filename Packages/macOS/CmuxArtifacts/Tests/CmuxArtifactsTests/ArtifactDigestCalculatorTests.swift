import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact digest calculator")
struct ArtifactDigestCalculatorTests {
    @Test("SHA-256 bytes are encoded as lowercase hexadecimal")
    func encodesDigest() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write("abc", named: "digest.txt", under: root)

        let digest = try ArtifactDigestCalculator().digest(
            url: source,
            expectedSize: 3,
            allowedRoot: root
        )

        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Digest calculation never follows a symbolic link")
    func rejectsSymbolicLinks() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let target = try ArtifactTestSupport.write("abc", named: "target.txt", under: root)
        let link = root.appendingPathComponent("link.txt", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: ArtifactStoreError.self) {
            _ = try ArtifactDigestCalculator().digest(
                url: link,
                expectedSize: 3,
                allowedRoot: root
            )
        }
    }
}
