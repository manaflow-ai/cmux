import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact configuration safety")
struct ArtifactConfigurationSafetyTests {
    @Test("Oversized configuration fails closed without decoding")
    func oversizedConfigurationDisablesAutomaticCapture() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let configurationURL = ArtifactStorePaths(projectRoot: root).configurationFile
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data(#"{"automaticCaptureEnabled":true}"#.utf8)
        data.append(Data(repeating: 0x20, count: 64 * 1024))
        try data.write(to: configurationURL)

        let configuration = await LocalArtifactRepository().configuration(projectRoot: root)

        #expect(!configuration.automaticCaptureEnabled)
    }

    @Test("Symlinked configuration fails closed")
    func symlinkedConfigurationDisablesAutomaticCapture() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        let target = try ArtifactTestSupport.write(
            #"{"automaticCaptureEnabled":true}"#,
            named: "outside-artifacts.json",
            under: outside
        )
        let configurationURL = ArtifactStorePaths(projectRoot: root).configurationFile
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: configurationURL,
            withDestinationURL: target
        )

        let configuration = await LocalArtifactRepository().configuration(projectRoot: root)

        #expect(!configuration.automaticCaptureEnabled)
    }
}
