import CmuxNextResources
import Foundation
import Testing

/// Memory saved per discarded item (`taskManagerMemorySaved`): a discarded item shows the memory
/// of its last sample before the discard, the discarder's number wins, and the footer total sums
/// what is known.
@MainActor @Suite
struct TaskManagerMemorySavedTests {
    static let shell = ProcessKey(pid: 400), renderer = ProcessKey(pid: 500), webContent = ProcessKey(pid: 600)
    static let mb: UInt64 = 1 << 20

    static func sample(_ key: ProcessKey, memory: UInt64) -> ProcessSample {
        ProcessSample(key: key, name: "p\(key.pid)", cpuNanos: 0, memoryBytes: memory, sampledAtNanos: 1)
    }

    /// Mail and Inbox share one renderer (120 MB, 60 MB each); Docs has its own WebContent process
    /// (90 MB) and a 10 MB app-side estimate. A discarded tab has no process.
    static func set(discarded: [TaskManagerDiscardedItem] = []) -> TaskManagerSampleSet {
        let gone = Set(discarded.map(\.id))
        let tabs = [
            TabResourceSources(tabID: "tab_mail", title: "Mail", kind: .chromium, processes: [renderer]),
            TabResourceSources(tabID: "tab_inbox", title: "Inbox", kind: .chromium, processes: [renderer]),
            TabResourceSources(tabID: "tab_docs", title: "Docs", kind: .webkit, processes: [webContent],
                               estimatedAppBytes: 10 * mb),
            TabResourceSources(tabID: "tab_zsh", title: "zsh", kind: .terminal, processes: [shell]),
        ].map { tab in
            var tab = tab
            if gone.contains(tab.tabID) { tab.processes = [] }
            return tab
        }
        let live = Set(tabs.flatMap(\.processes))
        let memory: [ProcessKey: UInt64] = [renderer: 120 * mb, webContent: 90 * mb, shell: 5 * mb]
        let samples = Dictionary(uniqueKeysWithValues: memory.filter { live.contains($0.key) }.map { ($0.key, sample($0.key, memory: $0.value)) })
        return TaskManagerSampleSet(resources: ResourceSampleSet(tabs: tabs, samples: samples), discarded: discarded)
    }

    /// Hands out the queued sample sets in order, then repeats the last one.
    final class Source: TaskManagerSampleSource {
        var queue: [TaskManagerSampleSet]
        init(_ queue: [TaskManagerSampleSet]) { self.queue = queue }
        func sample() async -> TaskManagerSampleSet {
            queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }

    @Test func offByDefaultListsNoDiscardedItems() async {
        let source = Source([Self.set(discarded: [TaskManagerDiscardedItem(id: "tab_docs", title: "Docs", savedBytes: 80 * Self.mb)])])
        let model = TaskManagerModel(source: source, kill: { _ in })
        await model.refresh()
        #expect(!model.memorySaved)
        #expect(model.snapshot.discarded.isEmpty)
        #expect(model.snapshot.freedBytes == 0)
    }

    @Test func aDiscardedItemShowsItsLastSampleBeforeTheDiscard() async {
        let mail = TaskManagerDiscardedItem(id: "tab_mail", title: "Mail")
        let docs = TaskManagerDiscardedItem(id: "tab_docs", title: "Docs")
        let source = Source([Self.set(), Self.set(discarded: [mail]), Self.set(discarded: [mail, docs])])
        let model = TaskManagerModel(source: source, memorySaved: true, kill: { _ in })

        await model.refresh()
        #expect(model.snapshot.discarded.isEmpty)

        await model.refresh()
        #expect(model.snapshot.discarded.map(\.id) == ["tab_mail"])
        #expect(model.snapshot.discarded.first?.savedBytes == 60 * Self.mb, "half of the renderer it shared with Inbox")

        await model.refresh()
        #expect(model.snapshot.discarded.map(\.savedBytes) == [60 * Self.mb, 100 * Self.mb],
                "Mail keeps the number it had when discarded; Docs is its process plus its app-side estimate")
        #expect(model.snapshot.freedBytes == 160 * Self.mb)
    }

    @Test func theDiscardersNumberWinsAndAnUnseenItemIsUnknown() async {
        let docs = TaskManagerDiscardedItem(id: "tab_docs", title: "Docs", savedBytes: 80 * Self.mb)
        let old = TaskManagerDiscardedItem(id: "tab_old", title: "Old")
        let source = Source([Self.set(), Self.set(discarded: [docs, old])])
        let model = TaskManagerModel(source: source, memorySaved: true, kill: { _ in })
        await model.refresh()
        await model.refresh()
        #expect(model.snapshot.discarded.map(\.savedBytes) == [80 * Self.mb, nil])
        #expect(model.snapshot.freedBytes == 80 * Self.mb, "an item with no sample adds nothing to the total")
        #expect(model.snapshot.rows.allSatisfy { $0.id != Self.webContent }, "a discarded item is not a process row")
    }

    @Test func stopForgetsTheSamplesItSaw() async {
        let mail = TaskManagerDiscardedItem(id: "tab_mail", title: "Mail")
        let source = Source([Self.set(), Self.set(discarded: [mail])])
        let model = TaskManagerModel(source: source, memorySaved: true, kill: { _ in })
        await model.refresh()
        model.stop()
        await model.refresh()
        #expect(model.snapshot.discarded.map(\.savedBytes) == [nil],
                "after stop() the page has no sample of its own; only the discarder's number counts")
    }
}
