import CmuxMobileModel
import CmuxMobileTransport
import Foundation

/// Duplicate Workspace and Duplicate Workspace Without Browser Tabs from a phone, as the Mac's
/// (`WorkspaceStructureHandlers.duplicate`, `WorkspaceBlueprint`, `WorkspaceBlueprintBuilder`):
/// a new workspace with the same name, color and icon, screens, scrolling columns (and their
/// widths), splits (and their ratios) and tabs: every terminal again as a new shell in its
/// folder, every web page again (none without browser tabs). Agent chats and phone tabs are
/// not copied, as on the Mac. Every line is one the `daemon` lane already takes:
/// `new-workspace {name}`, `new-screen {workspace}`, `new-pane-right {pane, width}`,
/// `split {pane, dir}`, `new-tab {pane}`, `new-browser-tab {url, pane}`, `send` (the folder
/// typed as `cd`, since a phone never names a `cwd`), `set-split-ratio {split, ratio}`,
/// `set-workspace-metadata {color, icon}`, and `close-surface` / `close-workspace` to clean up.
extension LiveWorkspaceCreationBackend {
    /// A workspace's shape without its processes, as the Mac's `WorkspaceBlueprint`.
    struct DuplicateBlueprint: Hashable, Sendable {
        var screens: [Screen]

        struct Screen: Hashable, Sendable {
            var name: String
            /// Scrolling columns left to right; one entry with no width for a split screen.
            var columns: [Column]
        }

        struct Column: Hashable, Sendable {
            /// The column's width (`new-pane-right`'s `width`); nil for a split screen's tree.
            var width: Double?
            var root: Node
        }

        indirect enum Node: Hashable, Sendable {
            case pane([Tab])
            case split(axis: WorkspaceLayout.Axis, ratio: Double, first: Node, second: Node)

            var tabs: [Tab] {
                switch self {
                case .pane(let tabs): tabs
                case .split(_, _, let first, let second): first.tabs + second.tabs
                }
            }
        }

        enum Tab: Hashable, Sendable {
            /// A new shell; `folder` is typed as `cd` when it can be (nil: the Mac's default).
            case terminal(folder: String?)
            case browser(url: String)

            var isTerminal: Bool {
                if case .terminal = self { return true }
                return false
            }
        }

        var tabCount: Int { screens.flatMap(\.columns).map(\.root.tabs.count).reduce(0, +) }
    }

    /// The blueprint of `workspace` as the Mac listed it: each screen's columns (docks left
    /// out, as their chats are) or its one tree, each pane's terminals and web pages; with
    /// `browsers` false, no pages (a pane left empty goes and its split collapses). A
    /// workspace the Mac sent no layout for is one pane with its tabs in order. With nothing
    /// left, one terminal in the workspace's first folder.
    nonisolated static func duplicateBlueprint(_ workspace: Workspace, directories: [String: String],
                                               browsers: Bool) -> DuplicateBlueprint {
        let tabs = Dictionary(workspace.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func tab(_ id: String) -> DuplicateBlueprint.Tab? {
            guard let tab = tabs[id] else { return nil }
            switch tab.kind {
            case .terminal:
                return .terminal(folder: directories[tab.id] ?? tab.subtitle)
            case .browser:
                guard browsers, let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return .browser(url: url.absoluteString)
            case .agent, .simulator:
                return nil
            }
        }
        var screens: [DuplicateBlueprint.Screen] = []
        if let layout = workspace.layout {
            for screen in layout.screens {
                let paneTabs = Dictionary(screen.panes.map { ($0.id, $0.tabIDs) }, uniquingKeysWith: { first, _ in first })
                func capture(_ node: WorkspaceLayout.Node) -> DuplicateBlueprint.Node? {
                    switch node {
                    case .pane(let id):
                        let kept = (paneTabs[id] ?? []).compactMap(tab)
                        return kept.isEmpty ? nil : .pane(kept)
                    case .stack(let panes, _):
                        // Panes over each other: equal stacked splits, as the Mac's capture.
                        let nodes = panes.compactMap { capture(.pane($0)) }
                        guard var folded = nodes.last else { return nil }
                        for (offset, next) in nodes.dropLast().reversed().enumerated() {
                            folded = .split(axis: .vertical, ratio: 1 / Double(offset + 2), first: next, second: folded)
                        }
                        return folded
                    case .split(_, let axis, let ratio, let first, let second):
                        switch (capture(first), capture(second)) {
                        case let (a?, b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
                        case let (a?, nil): return a
                        case let (nil, b?): return b
                        case (nil, nil): return nil
                        }
                    }
                }
                let scrolling = screen.columns.filter { !$0.isDocked }
                let columns: [DuplicateBlueprint.Column] = scrolling.isEmpty
                    ? [screen.root.flatMap(capture).map { DuplicateBlueprint.Column(width: nil, root: $0) }].compactMap(\.self)
                    : scrolling.compactMap { column in
                        column.root.flatMap(capture).map { DuplicateBlueprint.Column(width: column.width, root: $0) }
                    }
                if !columns.isEmpty { screens.append(DuplicateBlueprint.Screen(name: screen.name, columns: columns)) }
            }
        } else {
            let kept = workspace.tabs.compactMap { tab($0.id) }
            if !kept.isEmpty { screens = [DuplicateBlueprint.Screen(name: "", columns: [DuplicateBlueprint.Column(width: nil, root: .pane(kept))])] }
        }
        if screens.isEmpty {
            let folder = workspace.tabs.lazy.compactMap { directories[$0.id] }.first
            screens = [DuplicateBlueprint.Screen(name: "", columns: [DuplicateBlueprint.Column(width: nil, root: .pane([.terminal(folder: folder)]))])]
        }
        return DuplicateBlueprint(screens: screens)
    }

    /// Builds `blueprint` into a new workspace named `name` (with `color` and `icon`), as the
    /// Mac's builder: one command at a time, since each needs the pane the one before made.
    /// A copy that fails partway is closed, never left half made.
    func buildDuplicate(_ blueprint: DuplicateBlueprint, name: String, color: String?, icon: String?,
                        on client: DaemonClient) async throws -> Workspace {
        let first = try Self.surface(await client.request("new-workspace", params: ["name": name]))
        let listed: DaemonTree
        do {
            listed = try await sync.listNow()
        } catch {
            _ = try? await client.request("close-surface", params: ["surface": first])
            throw error
        }
        let firstID = DaemonTree.tabID(surface: first)
        guard let pane = listed.tabPlaces[firstID]?.pane,
              let created = listed.workspaces.first(where: { $0.tabs.contains { $0.id == firstID } }) else {
            // Its first tab is all there is of it: close it, so no empty copy stays.
            _ = try? await client.request("close-surface", params: ["surface": first])
            throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
        }
        let pages = Self.streamsBrowser(capabilities(created.macID))
        let builder = DuplicateBuilder(client: client, sync: sync, pages: pages)
        do {
            for (index, screen) in blueprint.screens.enumerated() {
                if index == 0 {
                    try await builder.build(screen, pane: pane, initial: first)
                } else {
                    guard let number = sync.tree?.workspaceNumbers[created.id] else {
                        throw WorkspaceCreationError("The Mac doesn't list the new workspace")
                    }
                    let surface = try Self.surface(await client.request("new-screen", params: ["workspace": number]))
                    try await builder.build(screen, pane: try await builder.pane(holding: surface), initial: surface)
                }
            }
            try await builder.applyRatios(blueprint, workspace: created.id)
        } catch {
            _ = try? await client.request("close-workspace", params: ["key": created.id])
            throw error
        }
        // Color and icon as the Mac's builder sets them; a refusal leaves the copy as it is.
        if color != nil || icon != nil {
            _ = try? WorkspaceSync.check(await client.request("set-workspace-metadata",
                                                              params: Self.identityParams(created, color: color, icon: icon)))
        }
        let tree = try await sync.listNow()
        guard let copy = tree.workspaces.first(where: { $0.id == created.id }) else {
            throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
        }
        return copy
    }

    /// `set-workspace-metadata`'s params: the workspace, and its color and icon when set.
    nonisolated static func identityParams(_ workspace: Workspace, color: String?, icon: String?) -> sending [String: Any] {
        var params: [String: Any] = [:]
        if let color { params["color"] = color }
        if let icon { params["icon"] = icon }
        address(workspace, into: &params)
        return params
    }

    nonisolated static func surface(_ reply: Data) throws -> Int {
        guard let id = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
            throw WorkspaceCreationError("The Mac didn't say which tab it opened")
        }
        return id
    }
}

/// One duplicate's build, pane by pane (the Mac's `WorkspaceBlueprintBuilder`).
@MainActor
struct DuplicateBuilder {
    typealias Blueprint = LiveWorkspaceCreationBackend.DuplicateBlueprint
    let client: DaemonClient
    let sync: WorkspaceSync
    /// The Mac streams browser tabs (else pages are left out, as the Mac's builder does).
    let pages: Bool

    /// Fills `pane`, which holds one new terminal (`initial`), with `screen`'s first column,
    /// then adds its other columns to the right.
    func build(_ screen: Blueprint.Screen, pane: Int, initial: Int) async throws {
        guard let first = screen.columns.first else { return }
        try await fill(first.root, pane: pane, initial: initial)
        var previous = pane
        for column in screen.columns.dropFirst() {
            let surface = try LiveWorkspaceCreationBackend.surface(
                await client.request("new-pane-right", params: Self.columnParams(pane: previous, width: column.width)))
            let next = try await self.pane(holding: surface)
            try await fill(column.root, pane: next, initial: surface)
            previous = next
        }
    }

    /// `new-pane-right`'s params: the column to the left, and the new column's width when known.
    nonisolated static func columnParams(pane: Int, width: Double?) -> sending [String: Any] {
        var params: [String: Any] = ["pane": pane]
        if let width, width > 0 { params["width"] = width }
        return params
    }

    /// `pane` holds one new terminal (`initial`) started for `node`'s first tab.
    private func fill(_ node: Blueprint.Node, pane: Int, initial: Int) async throws {
        switch node {
        case .split(let axis, _, let first, let second):
            let surface = try LiveWorkspaceCreationBackend.surface(await client.request("split", params: ["pane": pane, "dir": axis.rawValue]))
            let other = try await self.pane(holding: surface)
            try await fill(first, pane: pane, initial: initial)
            try await fill(second, pane: other, initial: surface)
        case .pane(let tabs):
            var closeInitial = false
            for (index, tab) in tabs.enumerated() {
                switch tab {
                case .terminal(let folder):
                    // The pane's first terminal is the one it was made with.
                    let shell: Int
                    if index == 0 {
                        shell = initial
                    } else {
                        shell = try LiveWorkspaceCreationBackend.surface(await client.request("new-tab", params: ["pane": pane]))
                    }
                    if let folder, let line = LiveWorkspaceCreationBackend.changeDirectoryLine(folder) {
                        _ = try? await client.request("send", params: ["surface": shell, "text": line])
                    }
                case .browser(let url):
                    // A page that fails is left out (as elsewhere), never the tabs after it.
                    guard pages else { continue }
                    let opened = (try? WorkspaceSync.check(await client.request("new-browser-tab", params: ["url": url, "pane": pane]))) != nil
                    if index == 0, opened { closeInitial = true }
                }
            }
            // A pane that starts with a page: its placeholder terminal goes once the page is
            // in, so the pane never empties.
            if closeInitial { _ = try? await client.request("close-surface", params: ["surface": initial]) }
        }
    }

    /// The pane that holds `surface`, from a fresh list.
    func pane(holding surface: Int) async throws -> Int {
        let tree = try await sync.listNow()
        guard let pane = tree.tabPlaces[DaemonTree.tabID(surface: surface)]?.pane else {
            throw WorkspaceCreationError("The Mac doesn't list the new pane")
        }
        return pane
    }

    /// Splits are made at the daemon's default ratio: set each to the blueprint's by walking
    /// both trees together (the builder keeps the original pane first in every split).
    func applyRatios(_ blueprint: Blueprint, workspace: String) async throws {
        let tree = try await sync.listNow()
        guard let built = tree.workspaces.first(where: { $0.id == workspace })?.layout else { return }
        for (screen, made) in zip(blueprint.screens, built.screens) {
            let scrolling = made.columns.filter { !$0.isDocked }
            let roots = scrolling.isEmpty ? [made.root].compactMap(\.self) : scrolling.compactMap(\.root)
            for (column, root) in zip(screen.columns, roots) { try await applyRatios(column.root, root) }
        }
    }

    private func applyRatios(_ node: Blueprint.Node, _ built: WorkspaceLayout.Node) async throws {
        guard case .split(_, let ratio, let a, let b) = node, case .split(let id, _, let current, let builtA, let builtB) = built else { return }
        if abs(current - ratio) > 0.001 {
            _ = try? WorkspaceSync.check(await client.request("set-split-ratio", params: ["split": id, "ratio": ratio]))
        }
        try await applyRatios(a, builtA)
        try await applyRatios(b, builtB)
    }
}
