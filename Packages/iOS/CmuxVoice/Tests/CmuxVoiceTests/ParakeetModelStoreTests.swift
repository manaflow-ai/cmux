import Foundation
import Testing
@testable import CmuxVoice

@MainActor
@Suite(.serialized) struct ParakeetModelStoreTests {
    @Test func startsIdleWhenModelMissing() throws {
        let harness = try Harness()

        #expect(harness.store.state == .idle)
        #expect(!harness.store.isInstalled)
    }

    @Test func detectsInstalledModelAcrossRelaunch() throws {
        let harness = try Harness()
        try harness.installMarker()

        let reloaded = ParakeetModelStore(
            applicationSupportDirectory: harness.root,
            fileManager: harness.fileManager,
            downloader: harness.downloader,
            installedDetector: Harness.markerExists
        )
        #expect(reloaded.state == .installed)
        #expect(reloaded.isInstalled)
    }

    @Test func progressMapsToDownloadingThenInstalled() async throws {
        let harness = try Harness()

        harness.downloader.onDownload = { _, directory, progress in
            progress(ParakeetDownloadProgress(fractionCompleted: 0.25, phaseDescription: "downloading"))
            try Harness.installMarker(in: directory)
        }
        harness.store.downloadModel()
        await harness.downloader.waitForDownload()

        #expect(harness.store.state == .installed)
    }

    @Test func failureMovesToFailedState() async throws {
        let harness = try Harness()
        harness.downloader.onDownload = { _, _, _ in
            throw TestError.expected
        }

        harness.store.downloadModel()
        await harness.downloader.waitForDownload()

        guard case .failed(let message) = harness.store.state else {
            Issue.record("Expected failed state")
            return
        }
        #expect(!message.isEmpty)
        // The user-facing message must be cmux-domain copy, never the raw
        // underlying error string (which leaks domains/codes into the UI).
        #expect(!message.contains("expected"))
    }

    @Test func cancelResetsToIdleWhenNoModelWasInstalled() async throws {
        let harness = try Harness()
        harness.downloader.onDownload = { _, _, _ in
            try await Task.sleep(for: .seconds(60 * 60))
        }

        harness.store.downloadModel()
        await harness.downloader.waitUntilStarted()
        harness.store.cancelDownload()

        #expect(harness.store.state == .idle)
    }

    @Test func urlSessionCancellationResetsToIdleWhenNoModelWasInstalled() async throws {
        let harness = try Harness()
        harness.downloader.onDownload = { _, _, _ in
            throw URLError(.cancelled)
        }

        harness.store.downloadModel()
        await harness.downloader.waitForDownload()

        #expect(harness.store.state == .idle)
    }

    @Test func supersededCancelledAttemptCannotClobberNewDownload() async throws {
        let harness = try Harness()
        let coordinator = SupersededDownloadCoordinator()
        harness.downloader.onDownload = { _, directory, _ in
            let call = await coordinator.registerCall()
            if call == 1 {
                await coordinator.waitForFirstRelease()
                throw URLError(.cancelled)
            }
            try Harness.installMarker(in: directory)
        }

        harness.store.downloadModel()
        await coordinator.waitUntilFirstStarted()
        harness.store.cancelDownload()
        harness.store.downloadModel()

        await harness.downloader.waitUntilStarted(2)
        await harness.downloader.waitForDownload(1)
        #expect(harness.store.state == .installed)

        await coordinator.releaseFirst()
        await harness.downloader.waitForDownload(2)
        #expect(harness.store.state == .installed)
    }

    @Test func deleteModelRemovesFilesAndResetsIdle() throws {
        let harness = try Harness()
        try harness.installMarker()
        harness.store.refreshInstalledState()
        #expect(harness.store.state == .installed)

        try harness.store.deleteModel()

        #expect(harness.store.state == .idle)
        #expect(!harness.fileManager.fileExists(atPath: harness.store.modelDirectory.path))
    }

    @MainActor
    private struct Harness {
        let root: URL
        let fileManager = FileManager.default
        let downloader = FakeDownloader()
        let store: ParakeetModelStore

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("CmuxVoiceTests-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            store = ParakeetModelStore(
                applicationSupportDirectory: root,
                fileManager: fileManager,
                downloader: downloader,
                installedDetector: Self.markerExists
            )
        }

        func installMarker() throws {
            try Self.installMarker(in: store.modelDirectory)
        }

        nonisolated static func installMarker(in directory: URL) throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try "ok".write(to: directory.appendingPathComponent("model.marker"), atomically: true, encoding: .utf8)
        }

        nonisolated static func markerExists(at directory: URL) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.marker").path)
        }
    }

    private enum TestError: Error, LocalizedError {
        case expected

        var errorDescription: String? { "expected failure" }
    }
}

// Test-only fake is mutated before each serialized test starts its download.
private final class FakeDownloader: ParakeetModelDownloading, @unchecked Sendable {
    var onDownload: (@Sendable (ParakeetModelDescriptor, URL, @escaping @Sendable (ParakeetDownloadProgress) -> Void) async throws -> Void)?
    private let state = FakeDownloaderState()

    func download(
        _ descriptor: ParakeetModelDescriptor,
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        await state.markStarted()
        do {
            try await onDownload?(descriptor, directory, progress)
            await state.markFinished()
        } catch {
            await state.markFinished()
            throw error
        }
    }

    func waitUntilStarted() async {
        await state.waitUntilStarted()
    }

    func waitUntilStarted(_ count: Int) async {
        await state.waitUntilStarted(count)
    }

    func waitForDownload() async {
        await state.waitForFinished()
    }

    func waitForDownload(_ count: Int) async {
        await state.waitForFinished(count)
    }
}

private actor FakeDownloaderState {
    private var startedCount = 0
    private var finishedCount = 0
    private var startedContinuations: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishedContinuations: [(Int, CheckedContinuation<Void, Never>)] = []

    func markStarted() {
        startedCount += 1
        let ready = startedContinuations.filter { startedCount >= $0.0 }
        startedContinuations.removeAll { startedCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func markFinished() {
        finishedCount += 1
        let ready = finishedContinuations.filter { finishedCount >= $0.0 }
        finishedContinuations.removeAll { finishedCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilStarted() async {
        await waitUntilStarted(1)
    }

    func waitUntilStarted(_ count: Int) async {
        if startedCount >= count { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append((count, continuation))
        }
    }

    func waitForFinished() async {
        await waitForFinished(1)
    }

    func waitForFinished(_ count: Int) async {
        if finishedCount >= count { return }
        await withCheckedContinuation { continuation in
            finishedContinuations.append((count, continuation))
        }
    }
}

private actor SupersededDownloadCoordinator {
    private var callCount = 0
    private var firstStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstStarted = false
    private var firstReleased = false

    func registerCall() -> Int {
        callCount += 1
        if callCount == 1 {
            firstStarted = true
            let continuations = firstStartedContinuations
            firstStartedContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
        return callCount
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuations.append(continuation)
        }
    }

    func waitForFirstRelease() async {
        if firstReleased { return }
        await withCheckedContinuation { continuation in
            firstReleaseContinuations.append(continuation)
        }
    }

    func releaseFirst() {
        firstReleased = true
        let continuations = firstReleaseContinuations
        firstReleaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
