import Testing
@testable import CmuxNextTerminal

/// Starts the shared Ghostty runtime before each test of a suite that makes terminal surfaces.
///
/// The app starts libghostty's app on its launch's config build (`GhosttyRuntime.start(loadingOn:)`, since
/// a649fdca30f) and makes its terminals only after it; a test process has no launch, so a `TerminalSession` or
/// `TerminalSurfaceView` a test made before anything started the runtime had no surface (`surface == nil`), and the
/// test then passed or failed by which suite ran first. A suite that makes terminal surfaces carries `.ghosttyStarted`
/// instead of calling ``GhosttyRuntime/startedForTests()`` in each test, so a new test cannot miss it.
nonisolated struct GhosttyStarted: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    /// One scope per test function, not for the suite itself.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase != nil ? nil : self
    }

    @concurrent func provideScope(for test: Test, testCase: Test.Case?,
                                  performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await MainActor.run { _ = GhosttyRuntime.startedForTests() }
        try await function()
    }
}

extension Trait where Self == GhosttyStarted {
    /// The shared Ghostty runtime is started before each test, as the app's launch starts it before any terminal.
    static var ghosttyStarted: Self { GhosttyStarted() }
}
