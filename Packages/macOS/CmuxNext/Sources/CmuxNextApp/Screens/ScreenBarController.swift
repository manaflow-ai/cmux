import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTabs
import Observation

/// The bottom screen tab bar of one workspace: a `TabStripView` whose tabs
/// are the workspace's screens (Chrome sizing, hover card, drag reorder,
/// groups). It mirrors the daemon through `ScreenBarMapping` and turns
/// strip intents into `ScreenCommands` / `ScreenGroupCommands`.
@MainActor
final class ScreenBarController {
    let model = TabStripModel(style: .chrome, showsNewTabButton: true)
    let view: TabStripView
    private unowned let content: WorkspaceContentController
    private let preview: ScreenPreviewSource
    private var observation: Task<Void, Never>?
    /// Called when the bar should appear (two or more screens) or hide.
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isVisible = false
    /// A screen dragged out of the bar (to another workspace or window).
    private var drag: ScreenDragSession?

    private struct Snapshot: Equatable {
        var bar: ScreenBarMapping.Snapshot
        var active: String?
    }

    init(content: WorkspaceContentController) {
        self.content = content
        view = TabStripView(model: model)
        preview = ScreenPreviewSource(content: content)
        view.dragsWindowFromEmptySpace = false
        view.renamesOnDoubleClick = true
        view.previewProvider = preview
        view.setAccessibilityLabel(ScreenStrings.barAccessibility)
        model.intentHandler = { [weak self] intent in self?.handle(intent) }
        view.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        apply(snapshot())
        observation = Task { [weak self] in
            guard let content = self?.content else { return }
            for await snapshot in Observations({ Self.snapshot(content) }) { self?.apply(snapshot) }
        }
    }

    func teardown() {
        observation?.cancel()
        view.cancelInlineRename()
    }

    private func snapshot() -> Snapshot { Self.snapshot(content) }

    private static func snapshot(_ content: WorkspaceContentController) -> Snapshot {
        Snapshot(bar: ScreenBarMapping.snapshot(content.workspace, untitled: ScreenStrings.untitled, emojiIcon: ScreenEmojiIcon.icon),
                 active: content.layoutModel.activeScreenID?.rawValue)
    }

    private func apply(_ snapshot: Snapshot) {
        if model.groups != snapshot.bar.groups { model.groups = snapshot.bar.groups }
        if model.tabs != snapshot.bar.items { model.tabs = snapshot.bar.items }
        let selected = snapshot.active.map { StripTabID($0) }
        if model.selectedID != selected { model.selectedID = selected }
        if isVisible != snapshot.bar.isVisible {
            isVisible = snapshot.bar.isVisible
            if !isVisible { view.cancelInlineRename() }
            onVisibilityChange?(isVisible)
        }
    }

    /// Opens the inline editor on `screen` when the bar shows it.
    func beginRename(_ screen: ScreenModel) -> Bool {
        guard isVisible, model.tab(StripTabID(screen.id)) != nil else { return false }
        view.beginInlineRename(StripTabID(screen.id))
        return view.inlineRenameField != nil
    }

    // MARK: Intents

    private func screen(_ id: StripTabID) -> ScreenModel? { content.workspace.screens.first { $0.id == id.rawValue } }

    private func ref(_ id: StripTabID) -> ScreenRef? {
        screen(id).map { ScreenRef(workspace: content.workspace, screen: $0, daemon: content.daemon, content: content) }
    }

    private func handle(_ intent: TabStripIntent) {
        let daemon = content.daemon, services = content.services, workspace = content.workspace
        switch intent {
        case .select(let id):
            ScreenCommands.select(LayoutScreenID(id.rawValue), in: content)
        case .close(let id, _):
            if let screen = screen(id) { ScreenCommands.close([screen], in: workspace, daemon: daemon, services: services) }
        case .closeOthers(let keep):
            let others = workspace.screens.filter { $0.id != keep.rawValue && !$0.pinned }
            ScreenCommands.close(others, in: workspace, daemon: daemon, services: services)
        case .closeToRight(let id):
            guard let index = workspace.screens.firstIndex(where: { $0.id == id.rawValue }) else { return }
            ScreenCommands.close(Array(workspace.screens[(index + 1)...]), in: workspace, daemon: daemon, services: services)
        case .reorder(let id, _, let to):
            if let screen = screen(id) { ScreenCommands.move(screen, to: to, daemon: daemon) }
        case .newTab:
            ScreenCommands.create(in: workspace, daemon: daemon, content: content)
        case .pin(let id), .unpin(let id):
            let pin = if case .pin = intent { true } else { false }
            if let screen = screen(id) { ScreenCommands.setPinned(screen, pin, daemon: daemon) }
        case .rename(let id):
            view.beginInlineRename(id)
        case .renameCommitted(let id, let name):
            if let screen = screen(id) { ScreenCommands.rename(screen, to: name, daemon: daemon) }
        case .duplicate(let id):
            if let ref = ref(id) { ScreenCommands.duplicate(ref) }
        case .dragBegan(let start):
            guard let screen = screen(start.tabID) else { return view.restoreDetachedTab(start.tabID) }
            let session = ScreenDragSession(services: services, screen: screen, daemon: daemon, source: workspace,
                                            strip: view, tabID: start.tabID)
            session.onEnd = { [weak self] in self?.drag = nil }
            drag = session
            session.begin()
        case .groupDragBegan(let start):
            view.restoreDetachedGroup(start.groupID)
        case .toggleGroupCollapsed, .moveGroup, .addToGroup, .removeFromGroup, .group, .createGroup:
            handleGroup(intent)
        case .moveToNewSplit, .moveToNewColumn, .trailingButton:
            break
        }
    }

    private func groupRef(_ id: CmuxNextTabs.TabGroupID) -> ScreenGroupRef? {
        content.workspace.screenGroups.first { $0.id.rawValue == id.rawValue }.map {
            ScreenGroupRef(workspace: content.workspace, group: $0, daemon: content.daemon, content: content)
        }
    }

    private func handleGroup(_ intent: TabStripIntent) {
        let daemon = content.daemon
        switch intent {
        case .toggleGroupCollapsed(let id):
            if let ref = groupRef(id) { ScreenGroupCommands.setCollapsed(ref, !ref.group.collapsed) }
        case .moveGroup(let id, let to):
            ScreenGroupCommands.move(ScreenGroupID(rawValue: id.rawValue), to: to, daemon: daemon)
        case .addToGroup(let id, let group, let index):
            if let screen = screen(id) { ScreenGroupCommands.add([screen], to: ScreenGroupID(rawValue: group.rawValue), index: index, daemon: daemon) }
        case .removeFromGroup(let id, _):
            if let screen = screen(id) { ScreenGroupCommands.remove([screen], daemon: daemon) }
        case .createGroup(let item, let ids):
            ScreenGroupCommands.create(ids.compactMap(screen), in: content.workspace, name: item.name, color: item.colorToken, daemon: daemon)
        case .group(let command):
            run(command)
        default:
            break
        }
    }

    /// Editor bubble commands map one to one onto screen group commands.
    private func run(_ command: TabGroupCommand) {
        guard let ref = groupRef(command.groupID) else { return }
        let services = content.services
        switch command {
        case .rename(_, let name): ScreenGroupCommands.update(ref.group.id, name: name, daemon: ref.daemon)
        case .setColor(_, let color): ScreenGroupCommands.update(ref.group.id, color: color, daemon: ref.daemon)
        case .newTab: ScreenGroupCommands.newScreen(in: ref)
        case .ungroup: ScreenGroupCommands.ungroup(ref.group.id, daemon: ref.daemon)
        case .close: ScreenGroupCommands.close(ref, services: services)
        case .moveToNewWindow: ScreenGroupCommands.moveToNewWorkspace(ref.group.id, daemon: ref.daemon, services: services, newWindow: true)
        case .save: ScreenGroupCommands.save(ref.group.id, daemon: ref.daemon)
        case .unsave: ScreenGroupCommands.unsave(ref.group.id, daemon: ref.daemon)
        }
    }

    // MARK: Context menus

    private func contextMenu(for target: TabContextTarget) -> NSMenu? {
        let registry = content.services.registry
        switch target {
        case .tab(let id, _):
            return registry.makeContextMenu(for: .screen, target: ActionTargetRef(kind: .screen, id: id.rawValue))
        case .group(let id), .savedGroup(let id):
            return registry.makeContextMenu(for: .screenGroup, target: ActionTargetRef(kind: .screenGroup, id: id.rawValue))
        case .emptyStrip, .newTabButton:
            return registry.makeContextMenu(for: .screen, entries: [.action("screen.new"), .action("screen.newWith"),
                                                                     .action("screen.reopenClosed")])
        }
    }
}

/// Hover card thumbnails for screens: the preview of the screen's active
/// pane's selected tab (the terminal or page the screen shows first).
@MainActor
final class ScreenPreviewSource: TabPreviewProvider {
    private unowned let content: WorkspaceContentController

    init(content: WorkspaceContentController) { self.content = content }

    func previewImage(for tab: StripTabID, maxPixelSize: CGSize) async -> CGImage? {
        guard let screen = content.workspace.screens.first(where: { $0.id == tab.rawValue }),
              let pane = screen.defaultPane.flatMap(screen.pane) ?? screen.panes.first else { return nil }
        let selected = content.state.selection.selection(in: pane.id)
            ?? (pane.tabs.indices.contains(pane.defaultTabIndex) ? pane.tabs[pane.defaultTabIndex].id : pane.tabs.first?.id)
        guard let key = selected else { return nil }
        return await content.services.cache.previewImage(for: key, maxPixelSize: maxPixelSize)
    }
}
