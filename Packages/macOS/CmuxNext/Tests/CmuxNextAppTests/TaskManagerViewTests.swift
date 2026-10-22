import AppKit
@testable import CmuxNextResources
import Testing

/// The Task Manager page is an AppKit table (plans/cmux-next/no-swiftui-DESIGN.md): no SwiftUI
/// bridge; one row per process, a column click sorts, a row click selects it in the model, and
/// Kill Process runs the model's kill for the selected row.
@MainActor @Suite(.serialized)
struct TaskManagerViewTests {
    final class Source: TaskManagerSampleSource {
        var next = TaskManagerSampleSet.empty
        func sample() async -> TaskManagerSampleSet { next }
    }

    static func set(at second: UInt64) -> TaskManagerSampleSet {
        let keys = [ProcessKey(pid: 300), ProcessKey(pid: 100), ProcessKey(pid: 200)]
        let samples = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, ProcessSample(key: $0, name: "p\($0.pid)", cpuNanos: UInt64($0.pid) * second * 10_000_000,
                               memoryBytes: UInt64($0.pid) * 1024, sampledAtNanos: second * 1_000_000_000))
        })
        let resources = ResourceSampleSet(tabs: keys.map { TabResourceSources(tabID: "t\($0.pid)", title: "tab \($0.pid)", kind: .terminal, processes: [$0]) },
                                          shared: [], samples: samples)
        return TaskManagerSampleSet(resources: resources)
    }

    private static func subviews(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + subviews(of: $0) }
    }

    @Test func theTableListsSortsSelectsAndKills() async throws {
        _ = NSApplication.shared
        let source = Source()
        var killed: [ProcessKey] = []
        let model = TaskManagerModel(source: source, kill: { killed.append($0) })
        source.next = Self.set(at: 1)
        await model.refresh()
        source.next = Self.set(at: 2)
        await model.refresh()
        let view = TaskManagerView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.reload()
        view.layoutSubtreeIfNeeded()
        #expect(!hostsSwiftUI(view))
        let table = try #require(Self.subviews(of: view).first { $0 is NSTableView } as? NSTableView)
        #expect(table.numberOfRows == 3)

        let pid = try #require(table.tableColumns.first { $0.identifier.rawValue == "pid" })
        table.sortDescriptors = [try #require(pid.sortDescriptorPrototype)]
        #expect(view.shownRows.map(\.pid) == [100, 200, 300])
        table.sortDescriptors = [try #require(pid.sortDescriptorPrototype?.reversedSortDescriptor as? NSSortDescriptor)]
        #expect(view.shownRows.map(\.pid) == [300, 200, 100])

        let kill = try #require(Self.subviews(of: view).first { $0.accessibilityIdentifier() == "cmux.taskManager.kill" } as? NSButton)
        #expect(!kill.isEnabled, "nothing selected")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(model.selection == [ProcessKey(pid: 200)])
        #expect(kill.isEnabled)
        kill.performClick(nil)
        #expect(killed == [ProcessKey(pid: 200)])
    }
}

/// Whether `root`'s own view tree (not the inside of an AppKit control, whose private views on
/// macOS 26 include hosting views of AppKit's own) holds a SwiftUI hosting bridge.
@MainActor
private func hostsSwiftUI(_ root: NSView) -> Bool {
    if String(describing: type(of: root)).contains("Hosting") { return true }
    if root is NSControl { return false }
    return root.subviews.contains { hostsSwiftUI($0) }
}
