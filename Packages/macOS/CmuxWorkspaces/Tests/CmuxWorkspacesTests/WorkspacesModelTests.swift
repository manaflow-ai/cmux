import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class StubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String

    init(
        id: UUID = UUID(),
        groupId: UUID? = nil,
        isPinned: Bool = false,
        currentDirectory: String = "/tmp"
    ) {
        self.id = id
        self.groupId = groupId
        self.isPinned = isPinned
        self.currentDirectory = currentDirectory
    }
}

@MainActor
private final class RecordingHost: WorkspacesHosting {
    typealias Tab = StubTab

    private(set) var events: [String] = []
    /// Snapshot of `model.tabs` taken inside the willSet hook, to prove the
    /// hook fires while storage still holds the old value (parity).
    private(set) var tabsSeenDuringWillSet: [[UUID]] = []
    private(set) var selectionSeenDuringWillSet: [UUID?] = []
    var model: WorkspacesModel<StubTab>?

    func workspaceTabsWillChange(to newValue: [StubTab]) {
        events.append("tabs.willSet(\(newValue.count))")
        if let model {
            tabsSeenDuringWillSet.append(model.tabs.map(\.id))
        }
    }

    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) {
        events.append("groups.willSet(\(newValue.count))")
    }

    func selectedWorkspaceIdWillChange(to newValue: UUID?) {
        events.append("selection.willSet")
        if let model {
            selectionSeenDuringWillSet.append(model.selectedTabId)
        }
    }

    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {
        events.append("selection.didSet")
    }
}

@MainActor
struct WorkspacesModelTests {
    @Test
    func tabsWillSetHookFiresWhileStorageHoldsOldValue() {
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let first = StubTab()
        model.tabs = [first]
        let second = StubTab()
        model.tabs = [first, second]

        #expect(host.events == ["tabs.willSet(1)", "tabs.willSet(2)"])
        // During the second assignment the storage still held [first].
        #expect(host.tabsSeenDuringWillSet == [[], [first.id]])
    }

    @Test
    func selectionHooksFireInWillSetThenDidSetOrderWithOldAndNewValues() {
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let id = UUID()
        model.selectedTabId = id

        #expect(host.events == ["selection.willSet", "selection.didSet"])
        // willSet observed the pre-change storage (nil).
        #expect(host.selectionSeenDuringWillSet == [nil])
        #expect(model.selectedTabId == id)
    }

    @Test
    func hooksFireOnEqualValueAssignmentMatchingPublishedParity() {
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let id = UUID()
        model.selectedTabId = id
        model.selectedTabId = id
        model.workspaceGroups = []

        // the previous observer path emitted on every assignment, equal or not;
        // no-op guards belong in the host's hook bodies.
        #expect(host.events == [
            "selection.willSet", "selection.didSet",
            "selection.willSet", "selection.didSet",
            "groups.willSet(0)",
        ])
    }

    @Test
    func mutationsBeforeAttachFireNoHooks() {
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model

        model.tabs = [StubTab()]
        model.selectedTabId = UUID()
        model.attach(host: host)

        #expect(host.events.isEmpty)
        #expect(model.tabs.count == 1)
    }

    @Test
    func inPlaceArrayMutationFiresTabsHook() {
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        model.tabs.append(StubTab())
        model.tabs.removeAll()

        #expect(host.events == ["tabs.willSet(1)", "tabs.willSet(0)"])
    }
}
