import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextLaunch
import Testing

/// `AppServices` takes the registry's catalog from the environment's launch build and keeps
/// that read as `debug.startup`'s counter values; the launch warm-up thread's build leaves no main-thread wait.
@MainActor @Suite(.serialized)
struct ActionCatalogLaunchWiringTests {
    @Test func theRegistrysCatalogReadIsALaunchValue() throws {
        _ = NSApplication.shared
        var environment = AppEnvironment.current([:])
        let catalog = ActionCatalogLaunch()
        catalog.build()  // what LaunchWarmup's thread does before AppServices exists
        environment.actionCatalog = catalog
        let services = AppServices(environment: environment)

        let access = try #require(catalog.mainAccess, "AppServices.init reads the launch's catalog")
        #expect(access.outcome == .ready)
        #expect(services.launchValues.values[LaunchValueMarks.actionCatalogMainWait] == 0)
        #expect(services.launchValues.values[LaunchValueMarks.actionCatalogMainRead] == Double(access.microseconds))
        #expect(ActionCatalog.all.allSatisfy { services.registry.descriptor(for: $0.id) != nil })
    }

    @Test func withNoBuildStartedMainBuildsTheCatalogAndDoesNotWait() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let access = try #require(services.environment.actionCatalog.mainAccess)
        #expect(access.outcome == .builtOnMain)
        #expect(services.launchValues.values[LaunchValueMarks.actionCatalogMainWait] == 0)
    }
}
