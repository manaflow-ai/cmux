import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// hq#20297: while Settings is open, a change to anything the host lists read rebuilt every
/// section on the main thread (rooms, machines, devices parsed back from a string, browser
/// profiles, each theme level's choice, the Ghostty preview, diagnostics). The watch observes
/// each section on its own: a change rebuilds only the section that read it.
@MainActor @Suite(.serialized) struct SettingsHostSectionsRebuildTests {
    @Test func anUnrelatedChangeRebuildsOnlyItsOwnSection() async throws {
        let (page, cleanup) = try await Self.page()
        defer { cleanup() }
        let sources = Sources(count: 16)
        let builds = BuildCounter(count: 16)
        let sections = (0..<16).map { index in
            SettingsHostSection(name: "s\(index)") {
                builds.counts[index] += 1
                return ["s\(index)": .number(Double(sources[index]))]
            }
        }
        let events = EventLog()
        let subscription = try await page(sections).subscribe("cmux.settings.host.changed", filter: .object([:]),
                                                              context: PageCallContext(page: PageDescriptor.settings.id),
                                                              onEvent: { events.values.append($0) })
        defer { subscription.cancel() }
        try await Self.settle { builds.counts.allSatisfy { $0 == 1 } }
        #expect(builds.counts.allSatisfy { $0 == 1 }, "each section's baseline is built once: \(builds.counts)")

        builds.reset()
        sources[3] += 1
        try await Self.settle { events.values.count == 1 }
        #expect(builds.total == 1, "one change rebuilt \(builds.total) of 16 sections: \(builds.counts)")
        #expect(builds.counts[3] == 1)
        #expect(events.values.count == 1)
        // The event still carries the whole lists (the page's protocol is unchanged).
        guard case .object(let whole)? = events.values.last else { Issue.record("no event"); return }
        #expect(whole.count == 16)
        #expect(whole["s3"] == .number(1))
        #expect(whole["s0"] == .number(0))

        // Two sections changed in one main-actor turn: two rebuilds, one event.
        builds.reset()
        sources[5] += 1
        sources[9] += 1
        try await Self.settle { events.values.count == 2 }
        #expect(builds.total == 2, "two changes rebuilt \(builds.total) sections: \(builds.counts)")
        #expect(events.values.count == 2)
    }

    /// The shape before hq#20297, measured the same way: the whole lists as one watched read.
    @Test func theWholeListsAsOneReadRebuiltEverySection() async throws {
        let (page, cleanup) = try await Self.page()
        defer { cleanup() }
        let sources = Sources(count: 16)
        let builds = BuildCounter(count: 16)
        let whole = SettingsHostSection(name: "all") {
            (0..<16).reduce(into: [:]) { lists, index in
                builds.counts[index] += 1
                lists["s\(index)"] = .number(Double(sources[index]))
            }
        }
        let events = EventLog()
        let subscription = try await page([whole]).subscribe("cmux.settings.host.changed", filter: .object([:]),
                                                             context: PageCallContext(page: PageDescriptor.settings.id),
                                                             onEvent: { events.values.append($0) })
        defer { subscription.cancel() }
        try await Self.settle { builds.total == 16 }
        builds.reset()
        sources[3] += 1
        try await Self.settle { events.values.count == 1 }
        #expect(builds.total == 16, "one change rebuilt \(builds.total) of 16 sections")
    }

    @Test func theReadStillReturnsTheWholeLists() async throws {
        let (page, cleanup) = try await Self.page()
        defer { cleanup() }
        let provider = page([SettingsHostSection(name: "a") { ["a": .number(1)] },
                             SettingsHostSection(name: "b") { ["b": .bool(true), "c": .null] }])
        let lists = try await provider.call("cmux.settings.host.lists", params: .object([:]),
                                            context: PageCallContext(page: PageDescriptor.settings.id))
        #expect(lists == ["a": .number(1), "b": .bool(true), "c": .null])
    }

    private static func page() async throws -> (([SettingsHostSection]) -> SettingsPageProvider, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appending(path: "cn-settings-host-sections-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return ({ SettingsPageProvider(settings: settings, hostSections: $0) }, { try? FileManager.default.removeItem(at: url) })
    }

    /// Lets the watch's tasks run until `done` (2 s bound), then a few more turns so extra work would show.
    private static func settle(_ done: @MainActor () -> Bool) async throws {
        let start = ContinuousClock.now
        while !done(), ContinuousClock.now - start < .seconds(2) { try await Task.sleep(for: .milliseconds(2)) }
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Sixteen separate stores, as the real sections read separate stores.
@MainActor private final class Sources {
    let stores: [Store]
    init(count: Int) { stores = (0..<count).map { _ in Store() } }
    subscript(index: Int) -> Int {
        get { stores[index].value }
        set { stores[index].value = newValue }
    }
}

@MainActor @Observable private final class Store { var value = 0 }

@MainActor private final class BuildCounter {
    var counts: [Int]
    init(count: Int) { counts = Array(repeating: 0, count: count) }
    var total: Int { counts.reduce(0, +) }
    func reset() { counts = counts.map { _ in 0 } }
}

@MainActor private final class EventLog { var values: [JSONValue] = [] }
