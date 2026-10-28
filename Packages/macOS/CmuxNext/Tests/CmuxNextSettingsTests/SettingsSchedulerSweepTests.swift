import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextSettings sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-338): one case
/// per migrated owner class. A reload's load lands as one `visible` task on the app's scheduler (its read runs off
/// main); the Channels fact follows through a `visible` ServiceObservation; the diagnostic toasts take a window's
/// key notice through their presenter (the app's one AppEvents observer).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SettingsSchedulerSweepTests {
    static func make(_ work: MainWorkScheduler) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-settings-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [],
                                          mainWork: work)
        return (settings, home)
    }

    static func classes(_ work: MainWorkScheduler, _ owner: String) -> Set<MainWorkClass> {
        Set(work.budget.board.ownerSnapshot().owners.filter { $0.owner == owner }.map(\.workClass))
    }

    // MARK: R-hop (the reload's landing)

    @Test func aReloadLandsAsOneVisibleTask() async throws {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let (settings, home) = try Self.make(work)
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(settings.loadCount == 1, "the reload never landed")
        #expect(Self.classes(work, "Settings.reload") == [.visible], "the reload did not land as one visible task")
    }

    /// No watcher runs (no `start()`): every load here is one of these requests.
    @Test func requestsDuringAReadCoalesceIntoOneMoreRead() async throws {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let (settings, home) = try Self.make(work)
        defer { try? FileManager.default.removeItem(at: home) }
        settings.requestReload()
        settings.requestReload()
        settings.requestReload()
        await settings.waitForLoad(atLeast: 2)
        // test-deadline: a bound on a wait that must find nothing, not a settle
        try await Task.sleep(for: .milliseconds(200))
        #expect(settings.loadCount == 2, "three requests during one read made \(settings.loadCount) loads, not two")
    }

    // MARK: ServiceObservation (the Channels fact)

    @Test func theChannelsFactFollowsTheSettingAsAVisibleObservation() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let registry = ActionRegistry(catalog: [])
        let channels = HomeChannelsSetting().bind(into: registry, settings: { nil }, unavailable: "not ready", mainWork: work)
        #expect(channels.workClass == .visible)
        #expect(registry.context.contains(.homeChannelsEnabled) == DesignSettings.shared.homeChannelsEnabled,
                "the fact was not applied in the bind's turn")
        channels.cancel()
    }

    // MARK: R-notif (the diagnostic toasts' key notice)

    @Test func theDiagnosticToastsWatchKeyWindowsThroughThePresenter() throws {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let (settings, home) = try Self.make(work)
        defer { try? FileManager.default.removeItem(at: home) }
        // The app's presenter (CmuxNextSettingsWindow) puts this on the app's one AppEvents key observer;
        // SettingsAppKitSeamTests pins that end to end.
        let presenter = KeyWindowRecordingPresenter()
        settings.start(announcingDiagnostics: presenter)
        #expect(presenter.followers.count == 1, "the toasts do not follow key windows through the presenter")
        settings.stop()
    }
}

/// Records what the diagnostic toasts ask of the window side; shows no toast (no window).
@MainActor private final class KeyWindowRecordingPresenter: SettingsDiagnosticPresenting {
    var followers: [@MainActor () -> Void] = []

    func show(_ notice: SettingsDiagnosticToast, onAction: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? { nil }

    func followKeyWindows(_ windowBecameKey: @escaping @MainActor () -> Void) { followers.append(windowBecameKey) }
}
