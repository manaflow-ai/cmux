import Darwin
import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact source snapshots")
struct ArtifactSourceSnapshotTests {
    @Test("A staged source remains immutable when the original changes")
    func stagedSourceIsImmutable() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write("initial", named: "result.txt", under: root)
        let paths = ArtifactStorePaths(projectRoot: root)
        let lease = try ArtifactImportStagingLease.acquire(
            root: paths.importStagingRoot,
            fileManager: .default
        )
        defer { lease.finish() }
        let snapshot = try ArtifactSourceSnapshotter(fileManager: .default).snapshot(
            source: source,
            paths: paths,
            configuration: .defaultValue,
            stagedURL: lease.makeStagedURL()
        )

        try "changed after staging".write(to: source, atomically: true, encoding: .utf8)

        #expect(snapshot.size == 7)
        #expect(try String(contentsOf: snapshot.url, encoding: .utf8) == "initial")
    }

    @Test("A pre-canceled snapshot stops before staging bytes")
    func preCanceledSnapshotLeavesNoStagedFile() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            String(repeating: "artifact bytes", count: 1_024),
            named: "result.txt",
            under: root
        )
        let paths = ArtifactStorePaths(projectRoot: root)
        let lease = try ArtifactImportStagingLease.acquire(
            root: paths.importStagingRoot,
            fileManager: .default
        )
        defer { lease.finish() }
        let stagedURL = lease.makeStagedURL()

        let wasCanceled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try ArtifactSourceSnapshotter(fileManager: .default).snapshot(
                    source: source,
                    paths: paths,
                    configuration: .defaultValue,
                    stagedURL: stagedURL
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(wasCanceled)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @Test("A FIFO source is rejected without waiting for a writer")
    func fifoSourceDoesNotBlockCapture() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = root.appendingPathComponent("result.md")
        guard Darwin.mkfifo(source.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.EIO)
        }
        let paths = ArtifactStorePaths(projectRoot: root)
        let lease = try ArtifactImportStagingLease.acquire(
            root: paths.importStagingRoot,
            fileManager: .default
        )
        defer { lease.finish() }
        let stagedURL = lease.makeStagedURL()
        let rescue = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let descriptor = Darwin.open(source.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            try? await Task.sleep(for: .seconds(1))
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        #expect(throws: ArtifactStoreError.sourceNotRegularFile(source.path)) {
            _ = try ArtifactSourceSnapshotter(fileManager: .default).snapshot(
                source: source,
                paths: paths,
                configuration: .defaultValue,
                stagedURL: stagedURL
            )
        }
        let elapsed = startedAt.duration(to: clock.now)
        rescue.cancel()
        await rescue.value

        #expect(elapsed < .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
    }
}
