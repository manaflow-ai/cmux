import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Settings' first open after launch (2026-11-15, "Settings opens late"): every Settings page's
/// host-lists subscription built the whole host lists twice at its start (its baseline, then the
/// stream's first value), 20-35 ms each on the main thread while the page waited for its first screen
/// (the stall watchdog named `SettingsPageProvider.swift:400`). A subscription's start reads once.
@MainActor @Suite(.serialized) struct SettingsHostWatchReadsOnceTests {
    @Test func theHostListsSubscriptionReadsTheListsOnceAtItsStart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cn-settings-host-watch-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let counter = ReadCounter()
        let page = SettingsPageProvider(settings: settings, hostLists: { counter.reads += 1; return ["reads": .number(1)] })
        let subscription = try await page.subscribe("cmux.settings.host.changed", filter: .object([:]),
                                                    context: PageCallContext(page: PageDescriptor.settings.id), onEvent: { _ in })
        defer { subscription.cancel() }
        // The watch starts on its own task: let it take its baseline and wait for a change.
        let start = ContinuousClock.now
        while counter.reads == 0, ContinuousClock.now - start < .seconds(2) { try await Task.sleep(for: .milliseconds(2)) }
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        #expect(counter.reads == 1, "the host lists were built \(counter.reads) times for one subscription's start")
    }
}

@MainActor private final class ReadCounter { var reads = 0 }
