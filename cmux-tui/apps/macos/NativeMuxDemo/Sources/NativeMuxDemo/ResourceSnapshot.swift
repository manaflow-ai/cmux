import Foundation

struct ResourceIdentity: Decodable, Sendable {
    let id: String
    let name: String?
}

struct WorkspaceSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let index: UInt32
    let focused: Bool
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id, name, index, focused
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        index = try container.decode(UInt32.self, forKey: .index)
        guard index < UInt32(Int32.max) else {
            throw DecodingError.dataCorruptedError(
                forKey: .index,
                in: container,
                debugDescription: "Workspace index is outside the display range."
            )
        }
        focused = try container.decode(Bool.self, forKey: .focused)
        displayName = name.isEmpty
            ? L10n.format("workspace.number", "workspace %d", Int(index) + 1)
            : name
    }
}

struct ScreenSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let workspaceID: String
    let name: String?
    let index: UInt32
    let focused: Bool
    let layout: LayoutDocument
    let displayName: String
    let columnCountLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, name, index, focused, layout
        case workspaceID = "workspace_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        index = try container.decode(UInt32.self, forKey: .index)
        guard index < UInt32(Int32.max) else {
            throw DecodingError.dataCorruptedError(
                forKey: .index,
                in: container,
                debugDescription: "Screen index is outside the display range."
            )
        }
        focused = try container.decode(Bool.self, forKey: .focused)
        layout = try container.decode(LayoutDocument.self, forKey: .layout)
        if let name, !name.isEmpty {
            displayName = name
        } else {
            displayName = L10n.format("space.number", "%d", Int(index) + 1)
        }
        if case .viewport(_, _, let columns) = layout.root {
            let count = columns.count
            columnCountLabel = L10n.format(
                count == 1 ? "columns.count.one" : "columns.count.other",
                count == 1 ? "%d column" : "%d columns",
                count
            )
        } else {
            columnCountLabel = nil
        }
    }
}

struct PaneSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let screenID: String
    let name: String?
    let focused: Bool
    let zoomed: Bool
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id, name, focused, zoomed
        case screenID = "screen_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        screenID = try container.decode(String.self, forKey: .screenID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        focused = try container.decode(Bool.self, forKey: .focused)
        zoomed = try container.decode(Bool.self, forKey: .zoomed)
        if let name, !name.isEmpty {
            displayName = name
        } else {
            displayName = L10n.format("pane.short_id", "Pane %@", String(id.suffix(5)))
        }
    }
}

struct TabSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let paneID: String
    let name: String?
    let index: UInt32
    let displayIndex: Int
    let focused: Bool
    let contentKind: String
    let contentID: String

    enum CodingKeys: String, CodingKey {
        case id, name, index, focused
        case paneID = "pane_id"
        case contentKind = "content_kind"
        case contentID = "content_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        paneID = try container.decode(String.self, forKey: .paneID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        index = try container.decode(UInt32.self, forKey: .index)
        guard index < UInt32(Int32.max) else {
            throw DecodingError.dataCorruptedError(
                forKey: .index,
                in: container,
                debugDescription: "Tab index is outside the display range."
            )
        }
        displayIndex = Int(index) + 1
        focused = try container.decode(Bool.self, forKey: .focused)
        contentKind = try container.decode(String.self, forKey: .contentKind)
        contentID = try container.decode(String.self, forKey: .contentID)
    }
}

struct TerminalSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let tabID: String?
    let title: String
    let cols: UInt16
    let rows: UInt16
    let running: Bool
    let lifecycle: String

    enum CodingKeys: String, CodingKey {
        case id, title, cols, rows, running, lifecycle
        case tabID = "tab_id"
    }
}

struct BrowserSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let tabID: String
    let url: String
    let title: String
    let loading: Bool
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, url, title, loading, status
        case tabID = "tab_id"
    }
}

struct ResourceCursor: Decodable, Sendable {
    let generation: String
    let revision: String
}

enum FrontendResourceChangeKind: String, Decodable, Sendable {
    case upsert
    case delete
}

enum FrontendResourceValue: Sendable {
    case workspace(WorkspaceSnapshot)
    case screen(ScreenSnapshot)
    case pane(PaneSnapshot)
    case tab(TabSnapshot)
    case terminal(TerminalSnapshot)
    case browser(BrowserSnapshot)
    case ignored
}

struct FrontendResourceChange: Decodable, Sendable {
    let kind: FrontendResourceChangeKind
    let resource: String
    let id: String
    let value: FrontendResourceValue?

    private enum CodingKeys: String, CodingKey {
        case kind, resource, id, value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(FrontendResourceChangeKind.self, forKey: .kind)
        resource = try container.decode(String.self, forKey: .resource)
        id = try container.decode(String.self, forKey: .id)
        guard kind == .upsert else {
            value = nil
            return
        }
        guard container.contains(.value) else {
            throw DecodingError.keyNotFound(
                CodingKeys.value,
                .init(codingPath: decoder.codingPath, debugDescription: "resource upsert omitted value")
            )
        }
        switch resource {
        case "workspace": value = .workspace(try container.decode(WorkspaceSnapshot.self, forKey: .value))
        case "screen": value = .screen(try container.decode(ScreenSnapshot.self, forKey: .value))
        case "pane": value = .pane(try container.decode(PaneSnapshot.self, forKey: .value))
        case "tab": value = .tab(try container.decode(TabSnapshot.self, forKey: .value))
        case "terminal": value = .terminal(try container.decode(TerminalSnapshot.self, forKey: .value))
        case "browser": value = .browser(try container.decode(BrowserSnapshot.self, forKey: .value))
        default: value = .ignored
        }
    }
}

struct FrontendResourceDelta: Sendable {
    let previousRevision: String
    let revision: String
    let changes: [FrontendResourceChange]
}

enum FrontendResourceEvent: Decodable, Sendable {
    case snapshot(ResourceSnapshot)
    case delta(FrontendResourceDelta)

    private enum CodingKeys: String, CodingKey {
        case kind, snapshot, changes, revision
        case previousRevision = "previous_revision"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "snapshot":
            self = .snapshot(try container.decode(ResourceSnapshot.self, forKey: .snapshot))
        case "delta":
            self = .delta(FrontendResourceDelta(
                previousRevision: try container.decode(String.self, forKey: .previousRevision),
                revision: try container.decode(String.self, forKey: .revision),
                changes: try container.decode([FrontendResourceChange].self, forKey: .changes)
            ))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown resource event kind \(kind)"
            )
        }
    }
}

private struct FrontendResourceEnvelope: Decodable {
    let item: FrontendResourceEvent
}

actor FrontendResourceDecoder {
    func decode(_ envelopes: [Data]) -> [FrontendResourceEvent]? {
        let decoder = JSONDecoder()
        var events: [FrontendResourceEvent] = []
        events.reserveCapacity(envelopes.count)
        for envelope in envelopes {
            guard let decoded = try? decoder.decode(FrontendResourceEnvelope.self, from: envelope) else {
                return nil
            }
            events.append(decoded.item)
        }
        return events
    }
}

struct FrontendResourceImpact: OptionSet, Sendable {
    let rawValue: UInt8

    static let presentation = FrontendResourceImpact(rawValue: 1 << 0)
    static let selection = FrontendResourceImpact(rawValue: 1 << 1)
    static let terminalTitles = FrontendResourceImpact(rawValue: 1 << 2)
    static let terminalControllers = FrontendResourceImpact(rawValue: 1 << 3)
    static let topology: FrontendResourceImpact = [
        .presentation, .selection, .terminalControllers,
    ]
    static let terminalStructure: FrontendResourceImpact = [
        .presentation, .terminalTitles, .terminalControllers,
    ]
}

enum FrontendResourceApplication: Sendable {
    case ignored
    case changed(FrontendResourceImpact)
    case terminalTitle(id: String, title: String)
}

struct ResourceSnapshot: Decodable, Sendable {
    let machine: ResourceIdentity
    let session: ResourceIdentity
    private(set) var workspaces: [WorkspaceSnapshot]
    private(set) var orderedWorkspaces: [WorkspaceSnapshot]
    private(set) var screens: [ScreenSnapshot]
    private(set) var panes: [PaneSnapshot]
    private(set) var tabs: [TabSnapshot]
    private(set) var terminals: [TerminalSnapshot]
    private(set) var browsers: [BrowserSnapshot]
    private(set) var cursor: ResourceCursor

    private var screensByWorkspaceID: [String: [ScreenSnapshot]]
    private var spaceCountLabelsByWorkspaceID: [String: String]
    private var panesByID: [String: PaneSnapshot]
    private var tabsByPaneID: [String: [TabSnapshot]]
    private var terminalsByID: [String: TerminalSnapshot]
    private var browsersByID: [String: BrowserSnapshot]

    private enum CodingKeys: String, CodingKey {
        case machine, session, workspaces, screens, panes, tabs, terminals, browsers, cursor
    }

    private static func index<T>(_ values: [T], by key: (T) -> String, decoder: Decoder) throws -> [String: T] {
        var result: [String: T] = [:]
        result.reserveCapacity(values.count)
        for value in values {
            let id = key(value)
            guard result.updateValue(value, forKey: id) == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "duplicate resource id: \(id)"))
            }
        }
        return result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machine = try container.decode(ResourceIdentity.self, forKey: .machine)
        session = try container.decode(ResourceIdentity.self, forKey: .session)
        workspaces = try container.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        orderedWorkspaces = workspaces.sorted { $0.index < $1.index }
        screens = try container.decode([ScreenSnapshot].self, forKey: .screens)
        panes = try container.decode([PaneSnapshot].self, forKey: .panes)
        tabs = try container.decode([TabSnapshot].self, forKey: .tabs)
        terminals = try container.decode([TerminalSnapshot].self, forKey: .terminals)
        browsers = try container.decode([BrowserSnapshot].self, forKey: .browsers)
        cursor = try container.decode(ResourceCursor.self, forKey: .cursor)
        screensByWorkspaceID = Dictionary(grouping: screens, by: \.workspaceID)
            .mapValues { $0.sorted { $0.index < $1.index } }
        spaceCountLabelsByWorkspaceID = Self.spaceCountLabels(
            workspaces: workspaces,
            screensByWorkspaceID: screensByWorkspaceID
        )
        panesByID = try Self.index(panes, by: \.id, decoder: decoder)
        tabsByPaneID = Dictionary(grouping: tabs, by: \.paneID)
            .mapValues { $0.sorted { $0.index < $1.index } }
        terminalsByID = try Self.index(terminals, by: \.id, decoder: decoder)
        browsersByID = try Self.index(browsers, by: \.id, decoder: decoder)
    }

    func screens(in workspaceID: String) -> [ScreenSnapshot] {
        screensByWorkspaceID[workspaceID] ?? []
    }

    func screenCount(in workspaceID: String) -> Int {
        screensByWorkspaceID[workspaceID]?.count ?? 0
    }

    func spaceCountLabel(in workspaceID: String) -> String {
        spaceCountLabelsByWorkspaceID[workspaceID] ?? ""
    }

    func pane(_ id: String) -> PaneSnapshot? {
        panesByID[id]
    }

    func tabs(in paneID: String) -> [TabSnapshot] {
        tabsByPaneID[paneID] ?? []
    }

    func visibleTerminalPlacements(in screen: ScreenSnapshot) -> [String: String] {
        var placements: [String: String] = [:]
        for paneID in screen.layout.visiblePaneIDs {
            let tabs = tabs(in: paneID)
            guard let activeTab = tabs.first(where: { $0.focused }) ?? tabs.first,
                  activeTab.contentKind == "terminal",
                  terminalsByID[activeTab.contentID] != nil
            else { continue }
            placements[paneID] = activeTab.contentID
        }
        return placements
    }

    func terminal(for tab: TabSnapshot) -> TerminalSnapshot? {
        terminalsByID[tab.contentID]
    }

    mutating func upsertTerminal(_ terminal: TerminalSnapshot) {
        if let index = terminals.firstIndex(where: { $0.id == terminal.id }) {
            terminals[index] = terminal
        } else {
            terminals.append(terminal)
        }
        terminalsByID[terminal.id] = terminal
    }

    private static func spaceCountLabels(
        workspaces: [WorkspaceSnapshot],
        screensByWorkspaceID: [String: [ScreenSnapshot]]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: workspaces.map { workspace in
            let count = screensByWorkspaceID[workspace.id]?.count ?? 0
            let label = L10n.format(
                count == 1 ? "spaces.count.one" : "spaces.count.other",
                count == 1 ? "%d space" : "%d spaces",
                count
            )
            return (workspace.id, label)
        })
    }

    private mutating func rebuildScreens() {
        screensByWorkspaceID = Dictionary(grouping: screens, by: \.workspaceID)
            .mapValues { $0.sorted { $0.index < $1.index } }
        spaceCountLabelsByWorkspaceID = Self.spaceCountLabels(
            workspaces: workspaces,
            screensByWorkspaceID: screensByWorkspaceID
        )
    }

    private mutating func rebuildTabs() {
        tabsByPaneID = Dictionary(grouping: tabs, by: \.paneID)
            .mapValues { $0.sorted { $0.index < $1.index } }
    }

    mutating func apply(_ change: FrontendResourceChange) -> FrontendResourceApplication? {
        switch (change.kind, change.resource, change.value) {
        case (.upsert, "workspace", .some(.workspace(let workspace))):
            guard workspace.id == change.id else { return nil }
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
            orderedWorkspaces = workspaces.sorted { $0.index < $1.index }
            rebuildScreens()
            return .changed(.topology)

        case (.delete, "workspace", nil):
            guard workspaces.contains(where: { $0.id == change.id }) else { return .ignored }
            workspaces.removeAll { $0.id == change.id }
            orderedWorkspaces = workspaces.sorted { $0.index < $1.index }
            rebuildScreens()
            return .changed(.topology)

        case (.upsert, "screen", .some(.screen(let screen))):
            guard screen.id == change.id else { return nil }
            if let index = screens.firstIndex(where: { $0.id == screen.id }) {
                screens[index] = screen
            } else {
                screens.append(screen)
            }
            rebuildScreens()
            return .changed(.topology)

        case (.delete, "screen", nil):
            guard screens.contains(where: { $0.id == change.id }) else { return .ignored }
            screens.removeAll { $0.id == change.id }
            rebuildScreens()
            return .changed(.topology)

        case (.upsert, "pane", .some(.pane(let pane))):
            guard pane.id == change.id else { return nil }
            if let index = panes.firstIndex(where: { $0.id == pane.id }) {
                panes[index] = pane
            } else {
                panes.append(pane)
            }
            panesByID[pane.id] = pane
            return .changed(.topology)

        case (.delete, "pane", nil):
            guard panesByID.removeValue(forKey: change.id) != nil else { return .ignored }
            panes.removeAll { $0.id == change.id }
            return .changed(.topology)

        case (.upsert, "tab", .some(.tab(let tab))):
            guard tab.id == change.id else { return nil }
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[index] = tab
            } else {
                tabs.append(tab)
            }
            rebuildTabs()
            return .changed(.topology)

        case (.delete, "tab", nil):
            guard tabs.contains(where: { $0.id == change.id }) else { return .ignored }
            tabs.removeAll { $0.id == change.id }
            rebuildTabs()
            return .changed(.topology)

        case (.upsert, "terminal", .some(.terminal(let terminal))):
            guard terminal.id == change.id else { return nil }
            let previous = terminalsByID[terminal.id]
            let titleOnly = previous.map {
                $0.tabID == terminal.tabID
                    && $0.cols == terminal.cols
                    && $0.rows == terminal.rows
                    && $0.running == terminal.running
                    && $0.lifecycle == terminal.lifecycle
            } ?? false
            let unchanged = titleOnly && previous?.title == terminal.title
            upsertTerminal(terminal)
            if unchanged { return .ignored }
            if titleOnly {
                return .terminalTitle(id: terminal.id, title: terminal.title)
            }
            return .changed(.terminalStructure)

        case (.delete, "terminal", nil):
            guard terminalsByID[change.id] != nil else { return .ignored }
            removeTerminal(id: change.id)
            return .changed(.terminalStructure)

        case (.upsert, "browser", .some(.browser(let browser))):
            guard browser.id == change.id else { return nil }
            if let index = browsers.firstIndex(where: { $0.id == browser.id }) {
                browsers[index] = browser
            } else {
                browsers.append(browser)
            }
            browsersByID[browser.id] = browser
            return .changed(.presentation)

        case (.delete, "browser", nil):
            guard browsersByID.removeValue(forKey: change.id) != nil else { return .ignored }
            browsers.removeAll { $0.id == change.id }
            return .changed(.presentation)

        case (.upsert, _, .some(.ignored)), (.delete, _, nil):
            return .ignored

        default:
            return nil
        }
    }

    mutating func removeTerminal(id: String) {
        terminals.removeAll { $0.id == id }
        terminalsByID.removeValue(forKey: id)
    }

    mutating func setRevision(_ revision: String) {
        cursor = ResourceCursor(generation: cursor.generation, revision: revision)
    }

    func browser(for tab: TabSnapshot) -> BrowserSnapshot? {
        browsersByID[tab.contentID]
    }
}
