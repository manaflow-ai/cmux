import Testing
@testable import CmuxCEF

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
}
