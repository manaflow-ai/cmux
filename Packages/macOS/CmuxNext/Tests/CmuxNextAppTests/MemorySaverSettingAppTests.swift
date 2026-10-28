import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The app's `memory.saver` wiring, behind `memorySaverSetting`: a mode action run on
/// the app's registry sets the memory coordinator's mode and writes cmux-next.json; a failed write puts
/// the coordinator's previous mode back; cmux-next.json's value reaches the coordinator when the app
/// follows the setting. With the feature off, neither the actions nor the file change the mode.
@MainActor @Suite(.serialized) struct MemorySaverSettingAppTests {
    final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "cnc-memory-saver-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var file: URL { url.appending(path: "cmux-next.json") }
        func write(_ json: String) throws { try Data(json.utf8).write(to: file) }
    }

    static func services(featureOn: Bool) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                        overrides: FeatureOverrides(environmentEnabled: featureOn ? [Feature.memorySaverSetting.name] : []))
        return services
    }

    static func settings(_ services: AppServices, file: URL) async -> SettingsController {
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: file,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return settings
    }

    /// Runs `id` on the app's registry as `action.run` does and waits for its write.
    static func run(_ id: ActionID, on services: AppServices) async -> Bool {
        var ran = false
        let work = services.registry.capturingWork {
            ran = services.registry.perform(id, invocation: ActionInvocation(origin: .user))
        }
        for task in work { _ = await task.value }
        return ran
    }

    @Test func aModeActionSetsTheCoordinatorAndWritesTheFile() async throws {
        let folder = try Folder()
        try folder.write("{}")
        let services = Self.services(featureOn: true)
        AppActions.bind(services)
        services.settings = await Self.settings(services, file: folder.file)
        #expect(services.memoryCoordinator.mode == .medium)

        #expect(await Self.run(MemorySaverMode.off.actionID, on: services))
        #expect(services.memoryCoordinator.mode == .off, "memory.saver.off did not reach the app's memory coordinator")
        let written = try String(contentsOf: folder.file, encoding: .utf8)
        #expect(written.contains("\"saver\"") && written.contains("\"off\""), "cmux-next.json does not have memory.saver off: \(written)")
    }

    @Test func aFailedWritePutsTheCoordinatorsModeBack() async throws {
        let folder = try Folder()
        // The settings file's folder is a plain file, so every write of it fails.
        let blocker = folder.url.appending(path: "not-a-folder")
        try Data().write(to: blocker)
        let services = Self.services(featureOn: true)
        AppActions.bind(services)
        services.settings = await Self.settings(services, file: blocker.appending(path: "cmux-next.json"))

        _ = await Self.run(MemorySaverMode.aggressive.actionID, on: services)
        #expect(services.memoryCoordinator.mode == .medium, "the coordinator kept a mode cmux-next.json does not have")
    }

    @Test func settingsNotLoadedRefuseAndChangeNothing() async {
        let services = Self.services(featureOn: true)
        AppActions.bind(services)
        _ = await Self.run(MemorySaverMode.off.actionID, on: services)
        #expect(services.memoryCoordinator.mode == .medium, "an action with no settings changed the coordinator")
    }

    @Test func theFilesModeReachesTheCoordinator() async throws {
        let folder = try Folder()
        try folder.write(#"{"memory":{"saver":"aggressive"}}"#)
        let services = Self.services(featureOn: true)
        let settings = await Self.settings(services, file: folder.file)
        #expect(settings.snapshot.memorySaver == .aggressive)
        services.followMemorySaver(settings)
        #expect(services.memoryCoordinator.mode == .aggressive, "cmux-next.json's memory.saver did not reach the coordinator")
    }

    @Test func offTheFeatureNeitherTheActionsNorTheFileChangeTheMode() async throws {
        let folder = try Folder()
        try folder.write(#"{"memory":{"saver":"aggressive"}}"#)
        let services = Self.services(featureOn: false)
        AppActions.bind(services)
        let settings = await Self.settings(services, file: folder.file)
        services.settings = settings
        services.followMemorySaver(settings)
        #expect(services.memoryCoordinator.mode == .medium, "the file's mode applied with memorySaverSetting off")
        for mode in MemorySaverMode.allCases {
            #expect(services.registry.unavailableReason(for: mode.actionID) == MemorySaverSetting.featureOffReason)
            #expect(await Self.run(mode.actionID, on: services) == false, "\(mode.actionID.rawValue) ran with memorySaverSetting off")
        }
        #expect(services.memoryCoordinator.mode == .medium)
    }
}
