import Testing
@testable import CmuxCEF
import Foundation

@Suite("CEF runtime")
struct CEFRuntimeTests {
    @Test("Runtime reports uninitialized before bootstrap")
    @MainActor
    func uninitializedByDefault() {
        // Full initialization requires the app bundle with the CEF framework
        // and helper bundles; package tests only cover the inert state.
        #expect(!CEFRuntime.isInitialized)
        #expect(CEFRuntime.activeRemoteDebuggingPort == nil)
    }

    @Test("Shutdown is an inert, idempotent operation before initialization")
    @MainActor
    func shutdownBeforeInitialization() {
        CEFRuntimeLifecycleService().shutdown()
        CEFRuntimeLifecycleService().shutdown()
        #expect(!CEFRuntime.isInitialized)
    }

    @Test("Profile data service removes only an idle injected path")
    @MainActor
    func profileDataServiceUsesInjectedDependencies() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cef-profile-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let service = CEFRuntimeProfileDataService(
            fileManager: fileManager,
            runtimeIsInitialized: { false },
            profileCacheIsIdle: { _ in true }
        )
        #expect(service.removeIfIdle(at: directory.path))
        #expect(!fileManager.fileExists(atPath: directory.path))
    }
}
