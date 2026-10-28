import AppKit
@testable import CmuxNextApp
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextResources
import CmuxNextWakeups
import Foundation
import Testing

/// Memory saved per discarded item (`taskManagerMemorySaved`): the discarder records each page's
/// memory when it discards it (Chrome's `PreDiscardResourceUsage`), the Task Manager shows that
/// number and the footer sums what is known, and the page service turns it on from the feature.
@MainActor @Suite(.serialized)
struct TaskManagerMemorySavedTests {
    static let shell = ProcessKey(pid: 400), renderer = ProcessKey(pid: 500), webContent = ProcessKey(pid: 600)
    static let gpu = ProcessKey(pid: 700)
    static let mb: UInt64 = 1 << 20

    static func sample(_ key: ProcessKey, memory: UInt64) -> ProcessSample {
        ProcessSample(key: key, name: "p\(key.pid)", cpuNanos: 0, memoryBytes: memory, sampledAtNanos: 1)
    }

    /// Mail and Inbox share one renderer (120 MB, 60 MB each) and both list the shared GPU process
    /// (300 MB); Docs has its own WebContent process (90 MB) and a 10 MB app-side estimate; zsh is a
    /// terminal (5 MB).
    static func resources(docsAvailable: Bool = true) -> ResourceSampleSet {
        let tabs = [
            TabResourceSources(tabID: "tab_mail", title: "Mail", kind: .chromium, processes: [renderer, gpu]),
            TabResourceSources(tabID: "tab_inbox", title: "Inbox", kind: .chromium, processes: [renderer, gpu]),
            TabResourceSources(tabID: "tab_docs", title: "Docs", kind: .webkit, processes: [webContent],
                               estimatedAppBytes: 10 * mb, available: docsAvailable),
            TabResourceSources(tabID: "tab_zsh", title: "zsh", kind: .terminal, processes: [shell]),
        ]
        let memory: [ProcessKey: UInt64] = [renderer: 120 * mb, webContent: 90 * mb, shell: 5 * mb, gpu: 300 * mb]
        return ResourceSampleSet(tabs: tabs, shared: [SharedProcess(key: gpu, role: .gpu)],
                                 samples: Dictionary(uniqueKeysWithValues: memory.map { ($0.key, sample($0.key, memory: $0.value)) }))
    }

    /// Hands out the queued sample sets in order, then repeats the last one.
    final class Source: TaskManagerSampleSource {
        var queue: [TaskManagerSampleSet]
        init(_ queue: [TaskManagerSampleSet]) { self.queue = queue }
        func sample() async -> TaskManagerSampleSet {
            queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }

    // MARK: The one estimate

    @Test func aTabsMemoryIsItsShareOfItsOwnProcessesPlusItsEstimate() {
        let memory = Self.resources().tabMemory()
        #expect(memory["tab_mail"] == 60 * Self.mb, "half of the renderer it shares with Inbox; the GPU process is not a tab's")
        #expect(memory["tab_inbox"] == 60 * Self.mb)
        #expect(memory["tab_docs"] == 100 * Self.mb, "its WebContent process plus its app-side estimate")
        #expect(memory["tab_zsh"] == 5 * Self.mb)
    }

    /// Each number names the tabs it is shared with: Mail's moves when Inbox comes, goes or grows.
    /// The GPU process both list is no tab's, so it makes no sharer.
    @Test func eachReadingNamesTheTabsItsProcessesAreSharedWith() {
        let readings = Self.resources().tabMemoryReadings()
        #expect(readings["tab_mail"] == TabMemoryReading(bytes: 60 * Self.mb, sharers: ["tab_mail", "tab_inbox"]))
        #expect(readings["tab_inbox"]?.sharers == ["tab_mail", "tab_inbox"])
        #expect(readings["tab_docs"] == TabMemoryReading(bytes: 100 * Self.mb, sharers: ["tab_docs"]))
        #expect(readings.mapValues(\.bytes) == Self.resources().tabMemory())
        #expect(Self.resources().browserPageMemory["tab_mail"] == PageMemoryReading(bytes: 60 * Self.mb, sharers: ["tab_mail", "tab_inbox"]),
                "the hibernation's reading lost the sharers")
    }

    @Test func theEstimateListsOnlyTheKindsAskedForAndOnlyAvailableTabs() {
        let pages = Self.resources(docsAvailable: false).tabMemory(kinds: TabResourceKind.browserPages)
        #expect(Set(pages.keys) == ["tab_mail", "tab_inbox"], "no terminal, and no tab whose numbers are unavailable")
    }

    // MARK: The model shows the discarder's number

    @Test func offByDefaultListsNoDiscardedItems() async {
        let docs = TaskManagerDiscardedItem(id: "tab_docs", title: "Docs", savedBytes: 80 * Self.mb)
        let source = Source([TaskManagerSampleSet(resources: Self.resources(), discarded: [docs])])
        let model = TaskManagerModel(source: source, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                                     kill: { _ in })
        await model.refresh()
        #expect(!model.memorySaved)
        #expect(model.snapshot.discarded.isEmpty)
        #expect(model.snapshot.freedBytes == 0)
    }

    @Test func theDiscardersNumberShowsAndAnUnmeasuredItemIsUnknown() async {
        let docs = TaskManagerDiscardedItem(id: "tab_docs", title: "Docs", savedBytes: 80 * Self.mb)
        let old = TaskManagerDiscardedItem(id: "tab_old", title: "Old")
        let source = Source([TaskManagerSampleSet(resources: Self.resources(), discarded: [docs, old])])
        let model = TaskManagerModel(source: source, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                                     memorySaved: true, kill: { _ in })
        await model.refresh()
        #expect(model.snapshot.discarded.map(\.savedBytes) == [80 * Self.mb, nil])
        #expect(model.snapshot.freedBytes == 80 * Self.mb, "an item with no measurement adds nothing to the total")
    }

    /// Review of 49eb338: the model kept its own last sample of each tab and stop() cleared it, so
    /// closing and opening the Task Manager again changed "saved about 60 MB" into "Discarded".
    @Test func closingAndOpeningThePageAgainShowsTheSameNumber() async {
        let mail = TaskManagerDiscardedItem(id: "tab_mail", title: "Mail", savedBytes: 60 * Self.mb)
        let source = Source([TaskManagerSampleSet(resources: Self.resources(), discarded: [mail])])
        let model = TaskManagerModel(source: source, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                                     memorySaved: true, kill: { _ in })
        await model.refresh()
        model.stop()
        await model.refresh()
        #expect(model.snapshot.discarded.map(\.savedBytes) == [60 * Self.mb])
        #expect(model.snapshot.freedBytes == 60 * Self.mb)
    }

    @Test func theDiscardedItemsAreTheDiscardedTabsInTabOrder() {
        let tabs = Self.resources().tabs
        let items = TaskManagerDiscardedItem.list(in: tabs, isDiscarded: { $0 == "tab_docs" || $0 == "tab_mail" },
                                                  savedBytes: ["tab_docs": 100 * Self.mb])
        #expect(items == [
            TaskManagerDiscardedItem(id: "tab_mail", title: "Mail", savedBytes: nil),
            TaskManagerDiscardedItem(id: "tab_docs", title: "Docs", savedBytes: 100 * Self.mb),
        ])
    }

    // MARK: The app

    static func services(enabling names: Set<String> = []) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                        overrides: FeatureOverrides(environmentEnabled: names))
        return services
    }

    @Test func thePageServiceFollowsTheFeature() {
        let off = Self.services()
        #expect(!off.taskManager.memorySaved)
        #expect(!off.taskManager.source.memorySaved)

        let on = Self.services(enabling: [Feature.taskManagerMemorySaved.name])
        let page = on.taskManager
        #expect(page.memorySaved)
        #expect(page.source.memorySaved)
        _ = page.makeView(for: "task-manager-test", in: nil)
        #expect(page.model?.memorySaved == true, "the page's model lists the discarded items")
        page.tabClosed("task-manager-test")
        #expect(page.model == nil)
    }

    /// The discarder records the page's last reading when it discards it, keeps it while the page
    /// sleeps (a later reading of nothing does not replace it), and drops it when the page wakes.
    @Test func hibernationRecordsWhatThePageHeldWhenItWasDiscarded() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("saved", body: "<p>saved</p>")
        let key = page.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(page, for: key)
        rig.hibernation.noteMemory([key: PageMemoryReading(bytes: 50 * Self.mb, sharers: [key])])
        rig.hibernation.noteMemory([key: PageMemoryReading(bytes: 0, sharers: [key])])
        #expect(rig.hibernation.memoryBytes[key] == 50 * Self.mb, "a reading of nothing keeps the last one")
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        rig.services.cache.withdraw(key, by: rig.pane)
        try await rig.until("the page hibernated") { rig.isHibernated(key) }
        #expect(rig.hibernation.savedBytes[key] == 50 * Self.mb)

        rig.hibernation.noteMemory([key: PageMemoryReading(bytes: 7 * Self.mb, sharers: [key])])
        #expect(rig.hibernation.savedBytes[key] == 50 * Self.mb, "a sleeping page keeps what it held at the discard")

        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the page woke") { !rig.isHibernated(key) }
        #expect(rig.hibernation.savedBytes[key] == nil, "a page awake again saves nothing")
    }
}
