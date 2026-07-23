import Darwin
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

    @Test("A FIFO configuration fails closed without waiting for a writer")
    func fifoConfigurationDoesNotBlockRepository() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let configurationURL = ArtifactStorePaths(projectRoot: root).configurationFile
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard Darwin.mkfifo(configurationURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.EIO)
        }
        let rescue = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let descriptor = Darwin.open(configurationURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            try? await Task.sleep(for: .seconds(1))
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let configuration = await LocalArtifactRepository().configuration(projectRoot: root)
        let elapsed = startedAt.duration(to: clock.now)
        rescue.cancel()
        await rescue.value

        #expect(!configuration.automaticCaptureEnabled)
        #expect(elapsed < .milliseconds(500))
    }
}
