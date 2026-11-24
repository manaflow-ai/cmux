@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// The disk work before `CefInitialize` (the profile root, keeping the last run's log) runs off the main thread
/// from the preload, while the first window builds, so the start after the first frame does none of it (CMUX-571).
@MainActor struct CEFLaunchPrepOffMainTests {
    @Test func thePreloadKeepsTheLastLogBeforeAnyPageAsks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-launch-prep-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CEFProfileStorage(root: root.appending(path: "Chromium"))
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        try Data("last run".utf8).write(to: storage.logFile)

        let runtime = CEFRuntime(libraryLoader: { _ in .failure(.notEmbedded) }, storage: storage)
        runtime.preload(layout: CEFLibraryMapOffMainTests.layout)

        var kept = false
        for _ in 0..<200 where !kept {
            kept = FileManager.default.fileExists(atPath: storage.previousLogFile.path)
            if !kept { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(kept, "the last run's log is kept by the preload's off-main prep, not by a page's start")
        #expect(!FileManager.default.fileExists(atPath: storage.logFile.path))
        #expect(runtime.state == .loading, "no CefInitialize before a page asks")
    }
}

extension CEFLaunchPrepOffMainTests {
    /// Before the first window frame the prep does nothing (its reads and its thread would compete with the window
    /// build, a profiled A/B put the first frame 17 ms later); the frame's gate opens it, and the start that follows
    /// finds it done (CMUX-571).
    @Test func thePrepWaitsForTheFirstFrameThenKeepsTheLog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-launch-prep-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CEFProfileStorage(root: root.appending(path: "Chromium"))
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        try Data("last run".utf8).write(to: storage.logFile)

        let gate = FirstFrameGate()
        let runtime = CEFRuntime(libraryLoader: { _ in .failure(.notEmbedded) }, storage: storage)
        runtime.initializeAfter = gate
        runtime.preload(layout: CEFLibraryMapOffMainTests.layout)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: storage.previousLogFile.path), "no prep before the first frame")

        gate.open()
        _ = await runtime.launchPrepTask?.value
        #expect(FileManager.default.fileExists(atPath: storage.previousLogFile.path), "the frame opened the prep, and it is done")
    }

    /// The debug window's synchronous start has no preload, so it does the prep itself before `CefInitialize`: the
    /// profile root exists and the last run's log is kept, as on the async start (CMUX-571).
    @Test func theBlockingStartDoesThePrepItself() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-launch-prep-blocking-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CEFProfileStorage(root: root.appending(path: "Chromium"))
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        try Data("last run".utf8).write(to: storage.logFile)

        let runtime = CEFRuntime(libraryLoader: { _ in .failure(.notEmbedded) }, storage: storage)
        // The framework is not there, so the start fails after its prep.
        #expect(throws: BrowserEngineError.self) { try runtime.startBlocking(layout: CEFLibraryMapOffMainTests.layout) }
        #expect(FileManager.default.fileExists(atPath: storage.previousLogFile.path), "the blocking start kept the last run's log")
        #expect(runtime.launchPrepTask != nil, "a later start reuses the prep, not a second log rotation")
    }

    /// The built-in ad blocker's manifest is read by the prep, and the plan from it matches the plan read from disk,
    /// with and without the manifest, so `CefInitialize`'s main-thread turn reads no file for it (CMUX-571).
    @Test func thePrepReadsTheBuiltInManifest() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-launch-prep-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CEFProfileStorage(root: root.appending(path: "Chromium"))
        let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
        let extensions = CEFBuiltInExtensions(adBlockerEnabled: true)

        let without = CEFLaunchPrep(preparing: storage, resources: resources)
        #expect(!without.builtInManifest)
        #expect(without.plan(extensions, resources: resources) == extensions.plan(resources: resources, profiles: storage.root))

        let manifest = CEFBuiltInExtensions.adBlockerManifest(resources: resources)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifest)
        let with = CEFLaunchPrep(reading: storage, resources: resources)
        #expect(with.builtInManifest)
        #expect(with.plan(extensions, resources: resources) == extensions.plan(resources: resources, profiles: storage.root))
        #expect(with.plan(extensions, resources: resources).folders.count == 1)
    }
}
