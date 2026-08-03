import Foundation
import Testing
@testable import CmuxVoice

@MainActor
@Suite struct ParakeetModelCatalogTests {
    @Test func catalogHasAStoreForEveryDownloadableEngine() {
        let catalog = ParakeetModelCatalogStore(applicationSupportDirectory: Self.temporaryRoot())

        #expect(catalog.stores.map(\.engineID) == VoiceEngineID.downloadableCases)
        for engine in VoiceEngineID.downloadableCases {
            #expect(catalog.store(for: engine) != nil)
        }
    }

    @Test func installDetectionDistinguishesV3Int8AndInt4InSharedFolder() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root
            .appendingPathComponent("cmux-voice-models", isDirectory: true)
            .appendingPathComponent(ParakeetModelDescriptor.parakeetV3Int8.folderName, isDirectory: true)

        try Self.install(ParakeetModelDescriptor.parakeetV3Int8, in: directory)

        #expect(ParakeetModelStore.modelsExist(at: directory, descriptor: .parakeetV3Int8))
        #expect(!ParakeetModelStore.modelsExist(at: directory, descriptor: .parakeetV3Int4))

        try Self.createTopLevelItem("EncoderInt4.mlmodelc", in: directory)
        #expect(ParakeetModelStore.modelsExist(at: directory, descriptor: .parakeetV3Int4))
    }

    @Test func effectiveEngineFallsBackWhenSelectedModelMissing() {
        let settings = VoiceSettingsStore(defaults: Self.defaults())
        settings.selectedEngine = .parakeetV3Int4

        #expect(settings.effectiveEngine(installedEngines: []) == .apple)
        #expect(settings.effectiveEngine(installedEngines: [.parakeetV3Int4]) == .parakeetV3Int4)
    }

    @Test func deletingInstalledModelPreservesSharedFolderWhenSiblingIsDownloading() async throws {
        let root = Self.temporaryRoot()
        let gate = CatalogDownloadGate()
        let catalog = ParakeetModelCatalogStore(
            applicationSupportDirectory: root,
            downloader: CatalogBlockingDownloader(gate: gate)
        )
        let v3 = try #require(catalog.store(for: .parakeetV3))
        let compact = try #require(catalog.store(for: .parakeetV3Int4))
        defer {
            compact.cancelDownload()
            Task { await gate.release() }
            try? FileManager.default.removeItem(at: root)
        }

        try Self.install(.parakeetV3Int8, in: v3.modelDirectory)
        v3.refreshInstalledState()
        #expect(v3.isInstalled)

        compact.downloadModel()
        await gate.waitUntilStarted()
        #expect(compact.state.isDownloading)

        try catalog.deleteModel(for: .parakeetV3)

        #expect(!FileManager.default.fileExists(atPath: v3.modelDirectory.appendingPathComponent("Encoder.mlmodelc").path))
        #expect(FileManager.default.fileExists(atPath: compact.modelDirectory.appendingPathComponent("EncoderInt4.mlmodelc").path))
        #expect(FileManager.default.fileExists(atPath: compact.modelDirectory.appendingPathComponent("Preprocessor.mlmodelc").path))
        #expect(compact.state.isDownloading)

        await gate.release()
        await gate.waitUntilFinished()
        compact.refreshInstalledState()
        #expect(compact.isInstalled)
    }

    @Test func vocabularyBoostInstallDetectionRequiresCtcRuntimeFiles() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.createTopLevelItem("MelSpectrogram.mlmodelc", in: root)
        try Self.createTopLevelItem("AudioEncoder.mlmodelc", in: root)
        try Self.createTopLevelItem("vocab.json", in: root)
        #expect(!ParakeetVocabularyBoostStore.modelsExist(at: root))

        try Self.createTopLevelItem("tokenizer.json", in: root)
        #expect(ParakeetVocabularyBoostStore.modelsExist(at: root))
    }

    @Test func unknownEngineDecodesAsApple() throws {
        let data = Data("\"future-engine\"".utf8)
        let engine = try JSONDecoder().decode(VoiceEngineID.self, from: data)

        #expect(engine == .apple)
    }

    private static func install(_ descriptor: ParakeetModelDescriptor, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in descriptor.requiredTopLevelNames {
            try createTopLevelItem(name, in: directory)
        }
    }

    private static func createTopLevelItem(_ name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        if name.hasSuffix(".json") {
            try "{}".write(to: url, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CmuxVoiceCatalogTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func defaults() -> UserDefaults {
        let suite = "CmuxVoiceCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private struct CatalogBlockingDownloader: ParakeetModelDownloading {
    let gate: CatalogDownloadGate

    func download(
        _ descriptor: ParakeetModelDescriptor,
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        progress(ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: "downloading"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.install(descriptor, in: directory)
        if descriptor.engineID == .parakeetV3Int4 {
            await gate.markStarted()
            await gate.waitUntilReleased()
            await gate.markFinished()
        }
        progress(ParakeetDownloadProgress(fractionCompleted: 1, phaseDescription: "downloading"))
    }

    private static func install(_ descriptor: ParakeetModelDescriptor, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in descriptor.requiredTopLevelNames {
            try createTopLevelItem(name, in: directory)
        }
    }

    private static func createTopLevelItem(_ name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        if name.hasSuffix(".json") {
            try "{}".write(to: url, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

private actor CatalogDownloadGate {
    private var didStart = false
    private var didRelease = false
    private var didFinish = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishContinuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let continuations = startContinuations
        startContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        guard !didRelease else { return }
        didRelease = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitUntilReleased() async {
        guard !didRelease else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func markFinished() {
        didFinish = true
        let continuations = finishContinuations
        finishContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        guard !didFinish else { return }
        await withCheckedContinuation { continuation in
            finishContinuations.append(continuation)
        }
    }
}
