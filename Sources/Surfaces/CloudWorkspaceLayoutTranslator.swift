import Foundation

/// The geometry a machine workspace should open with on this Mac: the daemon screen's
/// split tree, with the catalog placements (resource + exact tab view) that belong in
/// each pane. Pure data; `SurfaceCatalog.projectGroupAsNewLocalWorkspace(_:layout:)`
/// walks it so a clicked workspace row (or `cmux vm workspace open`) reproduces the
/// machine's splits, ratios and tabs instead of a generic grid.
indirect enum SurfaceProjectionLayout: Hashable, Sendable {
    /// One local pane: `placements[0]` is what the pane shows, the rest are tabs in it.
    case leaf(placements: [SurfaceResourcePlacement])
    /// Two panes or subtrees side by side (`.right`) or stacked (`.down`). `ratio` is the
    /// first child's share of the split, already clamped to `0.1…0.9`.
    case split(direction: SurfaceSplitDirection, ratio: Double, first: SurfaceProjectionLayout, second: SurfaceProjectionLayout)

    /// Every placement in document order (first leaf first, tabs in pane order).
    var placements: [SurfaceResourcePlacement] {
        switch self {
        case .leaf(let placements):
            return placements
        case .split(_, _, let first, let second):
            return first.placements + second.placements
        }
    }

    func includingMissingPlacements(_ members: [SurfaceResourcePlacement]) -> SurfaceProjectionLayout {
        var included = Set(placements)
        return appendingToFirstLeaf(members.filter { included.insert($0).inserted })
    }

    /// The same tree with `extra` appended as tabs of its first leaf — where the tabs of a
    /// workspace's other screens go, since a local workspace has one screen.
    func appendingToFirstLeaf(_ extra: [SurfaceResourcePlacement]) -> SurfaceProjectionLayout {
        guard !extra.isEmpty else { return self }
        switch self {
        case .leaf(let placements):
            return .leaf(placements: placements + extra)
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction, ratio: ratio, first: first.appendingToFirstLeaf(extra), second: second)
        }
    }
}

/// A provider that can report a workspace's current geometry. Only the cmux-tui machine
/// provider conforms; This Mac and test providers do not, and every caller treats a
/// missing or failed answer as "open the way you always did".
@MainActor
protocol SurfaceProjectionLayoutProviding: AnyObject {
    func projectionLayout(workspaceID: String) async throws -> SurfaceProjectionLayout?
}

/// Turns a cmux-tui `session snapshot` into the `SurfaceProjectionLayout` of one workspace.
///
/// The daemon's `LayoutDocument` (spec `resource-operations-v2.json`) is walked node for
/// node: a `leaf` is a pane and its tabs, a `split` keeps its direction and ratio, a
/// `stack` becomes stacked panes with equal shares, and a `viewport` becomes side-by-side
/// columns weighted by their widths. Only the focused screen's tree is geometry; tabs of
/// the workspace's other screens are appended to the first pane. Tabs whose resource the
/// catalog does not know are dropped, a pane left with no tab collapses into its sibling,
/// and a document this translator does not understand yields `nil` rather than a guess.
enum CloudWorkspaceLayoutTranslator {
    /// Bonsplit refuses dividers closer than this to an edge; the machine may allow more.
    static let minimumRatio = 0.1
    static let maximumRatio = 0.9
    static let defaultRatio = 0.5

    /// The layout `machine`'s provider reports for `workspaceID` right now, or nil when the
    /// machine cannot say (asleep, an older daemon without layout documents, no screen).
    /// Never throws: geometry is a nicety on top of opening, not a precondition.
    @MainActor
    static func fetch(machine: SurfaceMachineID, workspaceID: String, catalog: SurfaceCatalog) async -> SurfaceProjectionLayout? {
        guard let provider = catalog.provider(for: machine) as? SurfaceProjectionLayoutProviding else { return nil }
        return try? await provider.projectionLayout(workspaceID: workspaceID)
    }

    /// Pure: `snapshot` is the decoded `session current snapshot --json` object, `resources`
    /// the catalog's resources (only those on `machine` matter).
    static func projectionLayout(
        snapshot: [String: Any],
        machine: SurfaceMachineID,
        workspaceID: String,
        resources: [SurfaceResource]
    ) -> SurfaceProjectionLayout? {
        guard let tables = Tables(snapshot: snapshot, machine: machine, workspaceID: workspaceID, resources: resources),
              let primary = tables.screens.first(where: { $0.focused }) ?? tables.screens.first,
              let document = primary.layout else {
            return nil
        }
        // `screens[].layout` is a LayoutDocument (`{version, screen_id, root, …}`); accept a
        // bare node too, in case a build inlines the root.
        let root: Any?
        if let nested = document["root"] {
            root = nested
        } else if document["kind"] != nil {
            root = document
        } else {
            root = nil
        }
        let tree: SurfaceProjectionLayout?
        do {
            tree = try build(root, screen: primary, tables: tables)
        } catch {
            return nil
        }
        guard let tree else { return nil }
        var extras: [SurfaceResourcePlacement] = []
        for screen in tables.screens where screen.id != primary.id {
            for paneID in tables.paneIDsByScreen[screen.id] ?? [] {
                extras += tables.placements(inPane: paneID, screen: screen)
            }
        }
        return tree.appendingToFirstLeaf(extras)
    }

    // MARK: - Snapshot tables

    struct Screen {
        var id: String
        var index: Int
        var focused: Bool
        /// Present only on daemons that publish layout documents.
        var layout: [String: Any]?
    }

    struct Tab: Hashable, Sendable {
        var id: String
        var paneID: String
        var index: Int?
        var focused: Bool?
        var name: String?
        var contentKind: String
        var contentID: String
    }

    struct Tables {
        let machine: SurfaceMachineID
        let workspace: SurfaceRemoteWorkspace
        /// This workspace's screens in daemon order.
        let screens: [Screen]
        let tabsByID: [String: Tab]
        /// A pane's tabs in daemon tab order.
        let tabsByPane: [String: [Tab]]
        /// A screen's panes in daemon order.
        let paneIDsByScreen: [String: [String]]
        let resourceIDs: Set<SurfaceResourceID>

        init?(snapshot: [String: Any], machine: SurfaceMachineID, workspaceID: String, resources: [SurfaceResource]) {
            let workspaceRows = (snapshot["workspaces"] as? [[String: Any]]) ?? []
            guard let match = workspaceRows.enumerated().first(where: { LayoutJSON.string($0.element["id"]) == workspaceID }) else {
                return nil
            }
            self.machine = machine
            workspace = SurfaceRemoteWorkspace(
                id: workspaceID,
                name: LayoutJSON.string(match.element["name"]) ?? workspaceID,
                index: LayoutJSON.integer(match.element["index"]) ?? match.offset,
                focused: match.element["focused"] as? Bool ?? false
            )
            let screenRows = (snapshot["screens"] as? [[String: Any]]) ?? []
            screens = screenRows.enumerated()
                .filter { entry in LayoutJSON.string(entry.element["workspace_id"]) == workspaceID }
                .compactMap { entry -> (offset: Int, screen: Screen)? in
                    guard let id = LayoutJSON.string(entry.element["id"]) else { return nil }
                    let screen = Screen(
                        id: id,
                        index: LayoutJSON.integer(entry.element["index"]) ?? entry.offset,
                        focused: entry.element["focused"] as? Bool ?? false,
                        layout: entry.element["layout"] as? [String: Any]
                    )
                    return (entry.offset, screen)
                }
                .sorted { ($0.screen.index, $0.offset) < ($1.screen.index, $1.offset) }
                .map { $0.screen }
            var tabsByID: [String: Tab] = [:]
            var ordered: [(order: (Int, Int), tab: Tab)] = []
            for (offset, raw) in ((snapshot["tabs"] as? [[String: Any]]) ?? []).enumerated() {
                guard let id = LayoutJSON.string(raw["id"]),
                      let contentKind = LayoutJSON.string(raw["content_kind"]),
                      let contentID = LayoutJSON.string(raw["content_id"]) else { continue }
                let tab = Tab(
                    id: id,
                    paneID: LayoutJSON.string(raw["pane_id"]) ?? "",
                    index: LayoutJSON.integer(raw["index"]),
                    focused: raw["focused"] as? Bool,
                    name: LayoutJSON.string(raw["name"]),
                    contentKind: contentKind,
                    contentID: contentID
                )
                tabsByID[id] = tab
                ordered.append(((tab.index ?? offset, offset), tab))
            }
            self.tabsByID = tabsByID
            var tabsByPane: [String: [Tab]] = [:]
            for entry in ordered.sorted(by: { $0.order < $1.order }) {
                tabsByPane[entry.tab.paneID, default: []].append(entry.tab)
            }
            self.tabsByPane = tabsByPane
            var paneIDsByScreen: [String: [String]] = [:]
            for raw in (snapshot["panes"] as? [[String: Any]]) ?? [] {
                guard let id = LayoutJSON.string(raw["id"]), let screenID = LayoutJSON.string(raw["screen_id"]) else { continue }
                paneIDsByScreen[screenID, default: []].append(id)
            }
            self.paneIDsByScreen = paneIDsByScreen
            resourceIDs = Set(resources.filter { $0.machine == machine }.map(\.id))
        }

        /// The catalog placement for one daemon tab: its resource, when the catalog knows it,
        /// with the exact view (tab, pane, screen) so the local pane renames and reuses right.
        func placement(for tab: Tab, screen: Screen, fallbackPaneID: String) -> SurfaceResourcePlacement? {
            let kind: SurfaceResourceKind
            switch tab.contentKind {
            case "terminal": kind = .terminal
            case "browser": kind = .browser
            // The daemon has used both words for a VNC screen tab (CmuxTuiSnapshotParser reads both).
            case "display", "screen": kind = .display
            default: return nil
            }
            let id = SurfaceResourceID(machine: machine, kind: kind, key: tab.contentID)
            guard resourceIDs.contains(id) else { return nil }
            let view = SurfaceRemoteView(
                tabID: tab.id,
                workspace: workspace,
                screenID: screen.id,
                paneID: tab.paneID.isEmpty ? fallbackPaneID : tab.paneID,
                name: tab.name,
                index: tab.index,
                focused: tab.focused
            )
            return SurfaceResourcePlacement(resource: id, remoteView: view)
        }

        func placements(inPane paneID: String, screen: Screen) -> [SurfaceResourcePlacement] {
            (tabsByPane[paneID] ?? []).compactMap { placement(for: $0, screen: screen, fallbackPaneID: paneID) }
        }
    }

    // MARK: - Document walk

    /// A node this translator cannot read. The whole layout is discarded — a partial
    /// geometry would put terminals in the wrong panes silently.
    struct UnreadableLayout: Error, Equatable {
        var detail: String
    }

    private static func build(_ raw: Any?, screen: Screen, tables: Tables) throws -> SurfaceProjectionLayout? {
        guard let object = raw as? [String: Any], let kind = LayoutJSON.string(object["kind"]) else {
            throw UnreadableLayout(detail: "layout node without a kind")
        }
        switch kind {
        case "leaf":
            let paneID = LayoutJSON.string(object["pane_id"]) ?? ""
            // The document's own tab order is authoritative; the tabs table backs it up
            // for daemons that emit a leaf without `tab_ids`.
            let listed = ((object["tab_ids"] as? [Any]) ?? []).compactMap { $0 as? String }.compactMap { tables.tabsByID[$0] }
            let tabs = listed.isEmpty ? (tables.tabsByPane[paneID] ?? []) : listed
            let placements = tabs.compactMap { tables.placement(for: $0, screen: screen, fallbackPaneID: paneID) }
            return placements.isEmpty ? nil : .leaf(placements: placements)
        case "split":
            guard let direction = splitDirection(LayoutJSON.string(object["direction"])) else {
                throw UnreadableLayout(detail: "split direction \(LayoutJSON.string(object["direction"]) ?? "missing")")
            }
            let first = try build(object["first"], screen: screen, tables: tables)
            let second = try build(object["second"], screen: screen, tables: tables)
            return combine(direction: direction, ratio: clampedRatio(object["ratio"]), first: first, second: second)
        case "stack":
            let paneIDs = ((object["pane_ids"] as? [Any]) ?? []).compactMap { $0 as? String }
            let leaves = paneIDs.compactMap { paneID -> SurfaceProjectionLayout? in
                let placements = tables.placements(inPane: paneID, screen: screen)
                return placements.isEmpty ? nil : .leaf(placements: placements)
            }
            return stacked(leaves, direction: .down, weights: Array(repeating: 1, count: leaves.count))
        case "viewport":
            var subtrees: [SurfaceProjectionLayout] = []
            var weights: [Double] = []
            for column in ((object["columns"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
                guard let subtree = try build(column["root"], screen: screen, tables: tables) else { continue }
                subtrees.append(subtree)
                let width = LayoutJSON.number(column["width"]) ?? 1
                weights.append(width.isFinite && width > 0 ? width : 1)
            }
            return stacked(subtrees, direction: .right, weights: weights)
        default:
            throw UnreadableLayout(detail: "layout node kind \(kind)")
        }
    }

    /// Daemon words → local split direction. `horizontal` is side by side and `vertical` is
    /// stacked (cmux-tui-core `resource_topology.rs`: horizontal ⇔ right, vertical ⇔ down).
    static func splitDirection(_ raw: String?) -> SurfaceSplitDirection? {
        switch raw {
        case "horizontal", "right": return .right
        case "vertical", "down": return .down
        default: return nil
        }
    }

    /// The first child's share, clamped to what a local divider accepts; anything that is
    /// not a finite number means "even".
    static func clampedRatio(_ raw: Any?) -> Double {
        guard let value = LayoutJSON.number(raw), value.isFinite else { return defaultRatio }
        return min(maximumRatio, max(minimumRatio, value))
    }

    private static func combine(direction: SurfaceSplitDirection, ratio: Double, first: SurfaceProjectionLayout?, second: SurfaceProjectionLayout?) -> SurfaceProjectionLayout? {
        switch (first, second) {
        case (let first?, let second?):
            return .split(direction: direction, ratio: ratio, first: first, second: second)
        case (let only?, nil), (nil, let only?):
            return only
        case (nil, nil):
            return nil
        }
    }

    /// `nodes` laid out along `direction`, each taking `weights[i]` of what is left: a
    /// right-nested chain of splits whose ratios reproduce the proportions.
    private static func stacked(_ nodes: [SurfaceProjectionLayout], direction: SurfaceSplitDirection, weights: [Double]) -> SurfaceProjectionLayout? {
        guard var result = nodes.last else { return nil }
        guard nodes.count > 1 else { return result }
        for index in stride(from: nodes.count - 2, through: 0, by: -1) {
            let remaining = weights[index...].reduce(0, +)
            let ratio = remaining > 0 ? clampedRatio(weights[index] / remaining) : defaultRatio
            result = .split(direction: direction, ratio: ratio, first: nodes[index], second: result)
        }
        return result
    }
}

/// Lenient readers for the snapshot's JSON values: an empty string reads as absent, and
/// numbers arrive as `Int`, `Double`, or `NSNumber` depending on the decoder path.
private enum LayoutJSON {
    static func string(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }
}
