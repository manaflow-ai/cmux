import Bonsplit
import Foundation

/// JSON-serializable snapshot of the Mac focus target for mobile Voice Mode.
struct MobileFocusSnapshotPayload: Equatable {
    let workspaceID: UUID?
    let workspaceTitle: String?
    let surfaceID: UUID?
    let surfaceTitle: String?
    let surfaceType: String?
    let isTerminal: Bool
    let layout: MobileFocusLayoutPayload?

    /// Empty focus snapshot used when no Mac window/tab manager is active.
    static let empty = MobileFocusSnapshotPayload(
        workspaceID: nil,
        workspaceTitle: nil,
        surfaceID: nil,
        surfaceTitle: nil,
        surfaceType: nil,
        isTerminal: false,
        layout: nil
    )

    /// Builds the focus snapshot for a tab manager's selected workspace.
    /// - Parameter tabManager: The tab manager whose current focus should be projected.
    /// - Returns: A snapshot for the selected workspace and focused panel.
    @MainActor
    static func snapshot(tabManager: TabManager) -> MobileFocusSnapshotPayload {
        guard let workspaceID = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .empty
        }
        let layout = MobileFocusLayoutPayload.snapshot(workspace: workspace)
        guard let surfaceID = workspace.focusedPanelId else {
            return MobileFocusSnapshotPayload(
                workspaceID: workspace.id,
                workspaceTitle: workspace.title,
                surfaceID: nil,
                surfaceTitle: nil,
                surfaceType: nil,
                isTerminal: false,
                layout: layout
            )
        }
        return MobileFocusSnapshotPayload(
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            surfaceID: surfaceID,
            surfaceTitle: workspace.panelTitle(panelId: surfaceID),
            surfaceType: workspace.panelKind(panelId: surfaceID),
            isTerminal: workspace.terminalPanel(for: surfaceID) != nil,
            layout: layout
        )
    }

    /// Hash of fields that should trigger a focus update.
    var summaryHash: Int {
        var hasher = Hasher()
        hasher.combine(workspaceID)
        hasher.combine(workspaceTitle)
        hasher.combine(surfaceID)
        hasher.combine(surfaceTitle)
        hasher.combine(surfaceType)
        hasher.combine(isTerminal)
        hasher.combine(layout)
        return hasher.finalize()
    }

    /// Converts the snapshot to the mobile JSON payload shape.
    /// - Parameter controller: The handle-ref source for workspace/surface refs.
    /// - Returns: A JSON object with nullable focus fields.
    @MainActor
    func jsonObject(controller: TerminalController = .shared) -> [String: Any] {
        var object: [String: Any] = [
            "workspace_id": workspaceID?.uuidString as Any? ?? NSNull(),
            "workspace_ref": controller.v2Ref(kind: .workspace, uuid: workspaceID),
            "workspace_title": workspaceTitle as Any? ?? NSNull(),
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "surface_ref": controller.v2Ref(kind: .surface, uuid: surfaceID),
            "surface_title": surfaceTitle as Any? ?? NSNull(),
            "surface_type": surfaceType as Any? ?? NSNull(),
            "is_terminal": isTerminal,
        ]
        if let layout {
            object["layout"] = layout.jsonObject()
        } else {
            object["layout"] = NSNull()
        }
        return object
    }
}

/// Flat normalized pane layout for the selected workspace in Voice Mode.
struct MobileFocusLayoutPayload: Equatable, Hashable {
    let panes: [MobileFocusLayoutPanePayload]

    @MainActor
    static func snapshot(workspace: Workspace) -> MobileFocusLayoutPayload? {
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        let container = normalizedContainer(for: snapshot)
        let panes = snapshot.panes
            .enumerated()
            .map { index, pane in
                MobileFocusLayoutPanePayload.snapshot(
                    pane: pane,
                    index: index,
                    container: container,
                    workspace: workspace
                )
            }
            .sorted()
        guard !panes.isEmpty else { return nil }
        return MobileFocusLayoutPayload(panes: panes)
    }

    private static func normalizedContainer(for snapshot: LayoutSnapshot) -> MobileFocusRectPayload {
        if snapshot.containerFrame.width > 0, snapshot.containerFrame.height > 0 {
            return MobileFocusRectPayload(
                x: snapshot.containerFrame.x,
                y: snapshot.containerFrame.y,
                width: snapshot.containerFrame.width,
                height: snapshot.containerFrame.height
            )
        }

        let frames = snapshot.panes.map(\.frame)
        guard let first = frames.first else {
            return MobileFocusRectPayload(x: 0, y: 0, width: 1, height: 1)
        }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for frame in frames.dropFirst() {
            minX = min(minX, frame.x)
            minY = min(minY, frame.y)
            maxX = max(maxX, frame.x + frame.width)
            maxY = max(maxY, frame.y + frame.height)
        }
        return MobileFocusRectPayload(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }

    func jsonObject() -> [String: Any] {
        [
            "kind": "rects",
            "panes": panes.map { $0.jsonObject() },
        ]
    }
}

struct MobileFocusLayoutPanePayload: Comparable, Equatable, Hashable {
    let index: Int
    let rect: MobileFocusRectPayload
    let surfaceID: UUID?
    let title: String?
    let surfaceType: String?
    let isTerminal: Bool
    let focused: Bool

    @MainActor
    static func snapshot(
        pane: PaneGeometry,
        index: Int,
        container: MobileFocusRectPayload,
        workspace: Workspace
    ) -> MobileFocusLayoutPanePayload {
        let surfaceID = pane.selectedTabId
            .flatMap(UUID.init(uuidString:))
            .flatMap { workspace.panelIdFromSurfaceId(TabID(uuid: $0)) }
        return MobileFocusLayoutPanePayload(
            index: index,
            rect: MobileFocusRectPayload.normalized(frame: pane.frame, in: container),
            surfaceID: surfaceID,
            title: surfaceID.flatMap { workspace.panelTitle(panelId: $0) },
            surfaceType: surfaceID.flatMap { workspace.panelKind(panelId: $0) },
            isTerminal: surfaceID.flatMap { workspace.terminalPanel(for: $0) } != nil,
            focused: surfaceID == workspace.focusedPanelId
        )
    }

    static func < (lhs: MobileFocusLayoutPanePayload, rhs: MobileFocusLayoutPanePayload) -> Bool {
        if lhs.rect.y != rhs.rect.y { return lhs.rect.y < rhs.rect.y }
        if lhs.rect.x != rhs.rect.x { return lhs.rect.x < rhs.rect.x }
        return lhs.index < rhs.index
    }

    func jsonObject() -> [String: Any] {
        [
            "kind": "pane",
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "title": title as Any? ?? NSNull(),
            "surface_type": surfaceType as Any? ?? NSNull(),
            "is_terminal": isTerminal,
            "focused": focused,
            "rect": rect.jsonObject(),
        ]
    }
}

struct MobileFocusRectPayload: Equatable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static func normalized(frame: PixelRect, in container: MobileFocusRectPayload) -> MobileFocusRectPayload {
        let width = max(container.width, 1)
        let height = max(container.height, 1)
        return MobileFocusRectPayload(
            x: clamped((frame.x - container.x) / width),
            y: clamped((frame.y - container.y) / height),
            width: clamped(frame.width / width),
            height: clamped(frame.height / height)
        )
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    func jsonObject() -> [String: Any] {
        [
            "x": x,
            "y": y,
            "w": width,
            "h": height,
        ]
    }
}
