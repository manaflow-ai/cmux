import Foundation
@testable import CmuxNextDaemon

/// The switch-at-scale fixture (scripts/perf-lab/corpus/stories/switch_scale.py, cmux-layout-snapshot/v2) as the
/// daemon tree and personal state a store applies: N workspaces in spaces (rooms) and groups, each workspace its
/// screens of split panes of mixed tabs (terminal, Chromium, WebKit, agent chat), plus Home. The Python script is the
/// one source of the shape; this type only reads its file. Ids are counters, names and URLs are made up from them.
struct SwitchScaleFixture: Decodable {
    struct Node: Decodable {
        var split: String?
        var children: [Node]?
        var tabs: [String]?
        var selected: Int?
    }

    struct Screen: Decodable {
        var tree: Node
        var focusedPane: Int
        enum CodingKeys: String, CodingKey { case tree, focusedPane = "focused_pane" }
    }

    struct Workspace: Decodable {
        var screens: [Screen]
        var activeScreen: Int
        var space: Int
        var group: Int?
        enum CodingKeys: String, CodingKey { case screens, space, group, activeScreen = "active_screen" }
    }

    struct Group: Decodable { var space: Int }

    struct Window: Decodable {
        var display: Int
        var space: Int
        var workspace: Int
    }

    var schema: String
    var spaces: Int
    var groups: [Group]
    var workspaces: [Workspace]
    var windows: [Window]
    var home: Bool

    static let schemaName = "cmux-layout-snapshot/v2"
    static let session = "s-local"
    static let homeKey = "home"

    /// The fixture of `workspaces` workspaces: the file `CMUX_SWITCH_SCALE_LAYOUT_DIR/fixture-<n>.json` when that
    /// directory is set, else the generator's output for `n`, written to a temporary file.
    static func load(workspaces: Int) async throws -> SwitchScaleFixture {
        let environment = ProcessInfo.processInfo.environment
        let file: URL
        if let directory = environment["CMUX_SWITCH_SCALE_LAYOUT_DIR"], !directory.isEmpty {
            file = URL(fileURLWithPath: directory).appendingPathComponent("fixture-\(workspaces).json")
        } else {
            file = FileManager.default.temporaryDirectory.appendingPathComponent("switch-scale-\(getpid())-\(workspaces).json")
            try await generate(workspaces: workspaces, into: file)
        }
        let fixture = try JSONDecoder().decode(SwitchScaleFixture.self, from: try Data(contentsOf: file))
        guard fixture.schema == schemaName else { throw FixtureError.schema(fixture.schema) }
        return fixture
    }

    enum FixtureError: Error { case schema(String), generator(Int32, String) }

    /// The repository root, from this file's path (Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/).
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    /// Runs `switch_scale.py write` (the fixture's one source) and waits for its exit without blocking the thread.
    static func generate(workspaces: Int, into file: URL) async throws {
        let script = repositoryRoot.appendingPathComponent("scripts/perf-lab/corpus/stories/switch_scale.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", script.path, "write", "--workspaces", String(workspaces), "--out", file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let text = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
            throw FixtureError.generator(status, String(text.suffix(400)))
        }
    }

    static func room(_ space: Int) -> ProfileID { ProfileID(rawValue: "room\(space)") }
    static func key(_ index: Int) -> String { "k\(index)" }

    /// Tab, pane and screen counts, for the bench's report line.
    var counts: (screens: Int, panes: Int, tabs: Int) {
        var screens = 0, panes = 0, tabs = 0
        func walk(_ node: Node) {
            if let kinds = node.tabs { panes += 1; tabs += kinds.count } else { node.children?.forEach(walk) }
        }
        for workspace in workspaces { screens += workspace.screens.count; workspace.screens.forEach { walk($0.tree) } }
        return (screens, panes, tabs)
    }

    /// The daemon tree (with its personal state) the store applies.
    func tree() -> DaemonTree {
        var ids = IDs()
        var snapshots = workspaces.enumerated().map { index, workspace in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: Self.key(index)),
                              name: "Workspace \(index)",
                              screens: workspace.screens.enumerated().map { ids.screen($1, active: $0 == workspace.activeScreen) })
        }
        if home {
            var homeWorkspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(workspaces.count + 1)),
                                                  key: WorkspaceKey(rawValue: Self.homeKey), name: "Home",
                                                  screens: [ids.screen(Screen(tree: Node(tabs: ["terminal"], selected: 0), focusedPane: 0), active: true)])
            homeWorkspace.kind = "home"
            snapshots.append(homeWorkspace)
        }
        var tree = DaemonTree(registryID: Self.session, workspaces: snapshots)
        let rooms = (0..<spaces).map(Self.room)
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: Self.session)],
            profiles: rooms.enumerated().map { ProfileSnapshot(id: $1, name: "Space \($0)", index: $0) },
            pins: workspaces.enumerated().map { WorkspacePin(sessionID: Self.session, workspaceKey: WorkspaceKey(rawValue: Self.key($0)),
                                                             profile: Self.room($1.space)) },
            groups: groups.enumerated().map { WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "g\($0)"), name: "Group \($0)",
                                                                     index: $0, profile: Self.room($1.space)) },
            workspaces: workspaces.enumerated().map { index, workspace in
                PersonalWorkspace(sessionID: Self.session, workspaceKey: WorkspaceKey(rawValue: Self.key(index)), index: index,
                                  group: workspace.group.map { WorkspaceGroupID(rawValue: "g\($0)") })
            })
        return tree
    }

    /// Hands out the screen, pane and surface ids of the tree.
    struct IDs {
        var screenCount: UInt64 = 0
        var paneCount: UInt64 = 0
        var surfaceCount: UInt64 = 0

        mutating func screen(_ screen: Screen, active: Bool) -> ScreenSnapshot {
            screenCount += 1
            var panes: [PaneSnapshot] = []
            let laidOut = layout(screen.tree, into: &panes)
            let focused = panes.indices.contains(screen.focusedPane) ? panes[screen.focusedPane].id : panes.first?.id
            return ScreenSnapshot(id: ScreenID(rawValue: screenCount), active: active, activePane: focused, layout: laidOut, panes: panes)
        }

        /// The layout of `node`; its panes go into `panes` in leaf order. An n-way split is the daemon's chain of
        /// two-way splits, each child an even share.
        mutating func layout(_ node: Node, into panes: inout [PaneSnapshot]) -> LayoutNode {
            if let kinds = node.tabs {
                paneCount += 1
                var tabs: [TabSnapshot] = []
                for kind in kinds { tabs.append(tab(kind)) }
                panes.append(PaneSnapshot(id: PaneID(rawValue: paneCount), activeTab: min(node.selected ?? 0, tabs.count - 1), tabs: tabs))
                return .leaf(PaneID(rawValue: paneCount))
            }
            let children = node.children ?? []
            let direction: SplitDirection = node.split == "down" ? .down : .right
            var laid: [LayoutNode] = []
            for child in children { laid.append(layout(child, into: &panes)) }
            guard var chain = laid.last else { return .unknown }
            for (offset, child) in laid.dropLast().enumerated().reversed() {
                let share = 1.0 / Double(laid.count - offset)
                chain = .split(id: nil, resourceID: nil, direction: direction, ratio: share, a: child, b: chain)
            }
            return chain
        }

        mutating func tab(_ kind: String) -> TabSnapshot {
            surfaceCount += 1
            let n = surfaceCount, id = SurfaceID(rawValue: n)
            switch kind {
            case "chromium", "webkit":
                return TabSnapshot(surface: id, kind: .browser, title: "Page \(n)", url: "https://example.com/\(n)",
                                   browserEngine: kind)
            case "chat":
                var chat = TabSnapshot(surface: id, kind: .conversation, title: "Chat \(n)")
                chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:switch-scale", session: "s\(n)",
                                                                                     harness: "claude"))
                return chat
            default:
                return TabSnapshot(surface: id, title: "~")
            }
        }
    }
}
