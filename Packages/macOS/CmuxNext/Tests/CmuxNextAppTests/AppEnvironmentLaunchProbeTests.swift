import Foundation
import Testing
@testable import CmuxNextApp

/// p08-startup 033: `main` looks up the Ghostty resources once, before the environment freeze, and the launch's
/// environment is built on that answer instead of probing the disk again; the CLI helper is a launch read only the
/// real app sets.
@Suite("App environment on main's Ghostty lookup")
@MainActor
struct AppEnvironmentLaunchProbeTests {
    /// A folder with no `themes`: a fresh lookup would never pick it, so finding it in the environment proves
    /// the given answer was used as is.
    private let resolved = "/nonexistent/cmux-033/ghostty"

    @Test("The given resources are used, not looked up again")
    func theGivenResourcesAreUsed() {
        let environment = AppEnvironment.current([:], ghosttyResources: resolved)
        #expect(environment.ghosttyResources == resolved)
        #expect(environment.terminalEnvironment["GHOSTTY_RESOURCES_DIR"] == resolved)
        // No shell-integration folder under it: the app leaves shell integration to the daemon.
        #expect(!environment.resolvesShellIntegration)
    }

    @Test("No resources: shells get no resources folder and the daemon keeps its integration")
    func noResources() {
        let environment = AppEnvironment.current([:], ghosttyResources: nil)
        #expect(environment.ghosttyResources == nil)
        #expect(environment.terminalEnvironment["GHOSTTY_RESOURCES_DIR"] == nil)
        #expect(!environment.resolvesShellIntegration)
    }

    @Test("The CLI helper is a launch read only main sets")
    func theHelperIsUnsetOutsideMain() {
        #expect(AppEnvironment.current([:]).ghosttyBinary == nil)
        #expect(AppEnvironment.current([:], ghosttyResources: resolved).ghosttyBinary == nil)
    }

    @Test("The shell-integration check follows the resources folder")
    func shellIntegrationFollowsTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ghostty-033-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "shell-integration"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(AppEnvironment.current([:], ghosttyResources: folder.path).resolvesShellIntegration)
    }
}
