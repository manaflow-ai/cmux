#if DEBUG
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The deterministic capture registry keeps the Spaces gallery scene discoverable
/// for `cmux-ci capture ... --state scene:spaces-switcher`.
@MainActor
struct CaptureSceneSpacesTests {
    @Test func spacesSwitcherIsRegistered() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let scenes = try #require(CaptureSceneRegistry(services: services).list().arrayValue)
        #expect(scenes.contains { $0.objectValue?["name"]?.stringValue == "spaces-switcher" })
    }

    @Test func unavailableDaemonLeavesTheOriginalWindowAlone() async throws {
        let (services, original) = try FreshGroupUngroupTests.window()
        defer { services.windows.closeProgrammatically(original) }
        let windows = services.windows.controllers.map { $0.state.id }
        let result = await CaptureSceneRegistry(services: services).renderSpacesSwitcher([:], original: original)
        #expect(result.objectValue?["error"]?.stringValue == "spaces-switcher requires a daemon with profiles")
        #expect(services.windows.controllers.map { $0.state.id } == windows)
    }
}
#endif
