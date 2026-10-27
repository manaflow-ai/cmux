import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLaunch
@testable import CmuxNextSettings
import Foundation
import Testing

/// p08-startup-029 review: the platform services posted after the first frame or after startup, but four of
/// them set state that the first frame or the restore reads. These must be in place in the launch's own turn,
/// before any post runs: the hibernation (a page that the restore mounts hidden reports its hide to
/// `cache.hibernation`; when it is nil the hide is lost and the page is never a discard candidate), the
/// updater's settings follow (it must apply before `Updater.start`), the Chief pet (an arrival before startup
/// completes goes to it) and the glass mode (the first frame draws it).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PlatformServicesLaunchTests {
    @Test func whatTheFirstFrameAndTheRestoreReadIsSetBeforeAnyPostRuns() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-platform-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        let f = LaunchOrderFixture()

        services.startPlatformServices(settings: settings, on: f.order.startup, hotKeys: false)
        defer {
            services.cache.hibernation?.stop()
            services.updater.settingsObservation?.cancel()
        }

        // No frame has fired and startup has not completed: nothing posted ran.
        #expect(services.cache.hibernation != nil, "a page hidden by the restore must reach the hibernation")
        #expect(services.cache.warmSetRelease != nil, "the terminal warm set has its budget during the restore")
        #expect(services.updater.settingsObservation != nil, "updates.* must apply before Updater.start")
        #expect(services.notifications.chiefPet != nil, "an arrival before startup completes reaches the Chief pet")
        #expect(services.themeStore.glassMode == GlassLensMode.current(store: .shared, reduceTransparency: .shared,
                                                                         lowPowerMode: services.energyMonitor.lowPowerMode.isEnabled),
                "the first frame draws the resolved glass mode")
        f.hand.drain()
        let posted = f.order.startup.log.records.map(\.name.description)
        #expect(!posted.contains("Hibernation.start") && !posted.contains("Updater.follow"))
        #expect(posted.contains("Hibernation.measure") && posted.contains("Glass.observe") && posted.contains("Notifications.follow"))
        #expect(!posted.contains("GlobalHotKeys.start"), "an isolated launch takes no system-wide keys")
    }
}
