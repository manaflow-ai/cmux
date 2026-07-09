import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class StubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String
    var title: String
    private(set) var shellActivityUpdates: [(panelId: UUID, state: PanelShellActivityState)] = []

    init(
        id: UUID = UUID(),
        groupId: UUID? = nil,
        isPinned: Bool = false,
        currentDirectory: String = "/tmp",
        title: String = ""
    ) {
        self.id = id
        self.groupId = groupId
        self.isPinned = isPinned
        self.currentDirectory = currentDirectory
        self.title = title
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        shellActivityUpdates.append((panelId, state))
    }
    func setCustomColor(_ hex: String?) {}
    var focusedPanelId: UUID?
    var panelTitles: [UUID: String] = [:]
    func updatePanelTitle(panelId: UUID, title: String) -> Bool { false }
    func applyProcessTitle(_ title: String) {}
    // This fake never participates in panel-id resolution.
    func panelExists(_ panelId: UUID) -> Bool { false }
    func panelId(forSurfaceId surfaceId: UUID) -> UUID? { nil }
}

@MainActor
private final class RecordingHost: WorkspacesHosting {
    typealias Tab = StubTab

    private(set) var events: [String] = []
    private(set) var selectionSeenDuringWillSet: [UUID?] = []
    var model: WorkspacesModel<StubTab>?

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
    func tabsMutateAsPlainObservableStorageWithoutHostHooks() {
        // The `tabs` `objectWillChange`-re-emission willSet hook was retired
        // when `TabManager` became `@Observable`; `tabs` is now plain
        // `@Observable` storage and drives no host seam call.
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let first = StubTab()
        model.tabs = [first]
        model.tabs.append(StubTab())
        model.tabs.removeAll()
        model.workspaceGroups = []

        #expect(host.events.isEmpty)
        #expect(model.tabs.isEmpty)
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
    func selectionHooksFireOnEqualValueAssignmentMatchingPublishedParity() {
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let id = UUID()
        model.selectedTabId = id
        model.selectedTabId = id

        // The legacy `@Published` observer fired on every assignment, equal or
        // not; the selection hooks preserve that — no-op guards belong in the
        // host's hook bodies.
        #expect(host.events == [
            "selection.willSet", "selection.didSet",
            "selection.willSet", "selection.didSet",
        ])
    }

    @Test
    func selectionMutationBeforeAttachFiresNoHooks() {
        let model = WorkspacesModel<StubTab>()
        let host = RecordingHost()
        host.model = model

        model.tabs = [StubTab()]
        model.selectedTabId = UUID()
        model.attach(host: host)

        #expect(host.events.isEmpty)
        #expect(model.tabs.count == 1)
    }
}
