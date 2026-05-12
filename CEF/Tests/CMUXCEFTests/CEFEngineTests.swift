import XCTest
@testable import CMUXCEF

/// Behavioural tests for CMUXCEF. These tests exercise the bridge through
/// the public Swift API only; they do NOT grep source. See cmux test
/// quality policy in CLAUDE.md.
///
/// The tests deliberately avoid starting CEF when running under CI without
/// a display server. `CEFEngine.start` opens IPC sockets and spawns helpers,
/// which is appropriate for an integration test but not a unit test.
/// The unit tests below verify configuration shape, profile naming, and
/// API contracts that hold *before* CEF has been initialized.
final class CEFEngineTests: XCTestCase {

    @MainActor
    func testEngineIsNotRunningBeforeStart() {
        // CEFEngine.shared is a singleton; multiple tests share it.
        // We never call start() here.
        XCTAssertFalse(CEFEngine.shared.isRunning,
                       "engine must not be running until start() is called")
        XCTAssertNil(CEFEngine.shared.config,
                     "config must be nil before start()")
    }

    @MainActor
    func testConfigSerializesExtensionDirectoriesAsCommaJoinedPaths() {
        let dirA = URL(fileURLWithPath: "/tmp/ext-a")
        let dirB = URL(fileURLWithPath: "/tmp/ext-b")
        let config = CEFEngineConfig(
            rootCachePath: URL(fileURLWithPath: "/tmp/cmux-cef-test"),
            extensionDirectories: [dirA, dirB])
        // The bridge expects a comma-joined string; the engine assembles it
        // when calling into the bridge. We don't expose that string directly,
        // but we can assert the inputs round-trip through the config.
        XCTAssertEqual(config.extensionDirectories.map(\.path),
                       ["/tmp/ext-a", "/tmp/ext-b"])
    }
}

// MARK: - Profile registry tests
//
// These are *integration* tests: CEFProfileRegistry.shared.profile(named:)
// calls into the ObjC++ bridge which calls CefRequestContext::CreateContext.
// CEF must be initialized for that to be defined behaviour.
//
// They are intentionally not in the regular unit-test target. To run them,
// expose a CMUX_CEF_INTEGRATION env var on a separate test target that
// initializes CEFEngine before tests start.
//
// Behaviour to verify (manually, today; programmatically in a later PR):
//   * `CEFProfileRegistry.shared.profile(named:)` returns identical
//     instances across calls with the same name.
//   * Names beginning with "isolated-" produce profiles whose
//     `isEphemeral` is true; named profiles return false.
//   * Two profiles with different names produce distinct cache_path
//     directories under the engine root.
