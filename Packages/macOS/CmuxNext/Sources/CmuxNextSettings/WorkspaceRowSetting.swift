public import CmuxNextDesign

/// `sidebar.workspaceRow.*` (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE): one toggle
/// per row element, the second line's order, and the same keys under a
/// workspace kind (`sidebar.workspaceRow.terminal.directory`) to override them
/// for that kind. A missing key is its default; a bad value is the default
/// plus a diagnostic.
public nonisolated struct WorkspaceRowSetting: Sendable {
    public static let root = ["sidebar", "workspaceRow"]
    public static let orderKey = "secondLineOrder"
    /// The S1 keys these replace, read for one release when the new key is
    /// absent (like `sidebar.stickyBandsScroll`). The launch migration
    /// (`migrateLegacyWorkspaceRowKeys`) and every write of the new toggle
    /// remove them. Remove after the release.
    static let legacyPaths: [WorkspaceRowElement: [String]] = [
        .directory: ["sidebar", "showWorkspaceDirectory"],
        .tabCount: ["sidebar", "showCounts"],
    ]

    /// The S1 key a `sidebar.workspaceRow.<element>` key replaced, if any.
    static func legacyPath(for path: [String]) -> [String]? {
        guard path.count == root.count + 1, path.starts(with: root),
              let element = path.last.flatMap(WorkspaceRowElement.init(rawValue:)) else { return nil }
        return legacyPaths[element]
    }

    /// The S1 value that applies at `path` while the new key is absent: what
    /// Settings shows for the new toggle until the launch migration moves it.
    static func legacyValue(for path: [String], in root: JSONValue) -> JSONValue? {
        legacyPath(for: path).flatMap { root.value(at: $0) }
    }

    public init() {}

    public static func path(_ element: WorkspaceRowElement, kind: WorkspaceRowKind? = nil) -> [String] {
        root + (kind.map { [$0.rawValue] } ?? []) + [element.rawValue]
    }

    public static func orderPath(kind: WorkspaceRowKind? = nil) -> [String] {
        root + (kind.map { [$0.rawValue] } ?? []) + [orderKey]
    }

    public func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> WorkspaceRowPreferences {
        var shown = WorkspaceRowElements.minimal.shown
        for element in WorkspaceRowElement.allCases {
            var path = Self.path(element)
            if root.value(at: path) == nil, let legacy = Self.legacyPaths[element], root.value(at: legacy) != nil { path = legacy }
            guard let on = flag(root, path, &diagnostics) else { continue }
            if on { shown.insert(element) } else { shown.remove(element) }
        }
        let order = self.order(root, Self.orderPath(), &diagnostics) ?? WorkspaceRowElement.secondLine
        var overrides: [WorkspaceRowKind: WorkspaceRowOverride] = [:]
        for kind in WorkspaceRowKind.allCases {
            var change = WorkspaceRowOverride()
            for element in WorkspaceRowElement.allCases {
                if let on = flag(root, Self.path(element, kind: kind), &diagnostics) { change.elements[element] = on }
            }
            change.secondLineOrder = self.order(root, Self.orderPath(kind: kind), &diagnostics)
            if !change.isEmpty { overrides[kind] = change }
        }
        return WorkspaceRowPreferences(base: WorkspaceRowElements(shown: shown, secondLineOrder: order), overrides: overrides)
    }

    private func flag(_ root: JSONValue, _ path: [String], _ diagnostics: inout [SettingsDiagnostic]) -> Bool? {
        guard let value = root.value(at: path) else { return nil }
        guard let flag = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
            return nil
        }
        return flag
    }

    /// A list of second-line element names; nil when absent or invalid.
    private func order(_ root: JSONValue, _ path: [String], _ diagnostics: inout [SettingsDiagnostic]) -> [WorkspaceRowElement]? {
        guard let value = root.value(at: path) else { return nil }
        if case .array(let items) = value {
            let elements = items.map { $0.stringValue.flatMap(WorkspaceRowElement.init(rawValue:)) }
            if elements.allSatisfy({ $0?.isSecondLine == true }) { return elements.compactMap { $0 } }
        }
        let names = WorkspaceRowElement.secondLine.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                              message: "expected a list of " + names))
        return nil
    }
}

extension WorkspaceRowSetting {
    static func title(_ element: WorkspaceRowElement) -> SettingText {
        switch element {
        case .icon: SettingsText.keyed("settings.workspaceRow.icon", "Icon")
        case .directory: SettingsText.keyed("settings.workspaceRow.directory", "Folder")
        case .branch: SettingsText.keyed("settings.workspaceRow.branch", "Git Branch")
        case .process: SettingsText.keyed("settings.workspaceRow.process", "Running Program")
        case .agentStatus: SettingsText.keyed("settings.workspaceRow.agentStatus", "Agent Status")
        case .tabCount: SettingsText.keyed("settings.workspaceRow.tabCount", "Tab Count")
        case .ports: SettingsText.keyed("settings.workspaceRow.ports", "Ports")
        case .lastActivity: SettingsText.keyed("settings.workspaceRow.lastActivity", "Last Activity")
        case .pullRequest: SettingsText.keyed("settings.workspaceRow.pullRequest", "Pull Request")
        case .progress: SettingsText.keyed("settings.workspaceRow.progress", "Progress")
        case .working: SettingsText.keyed("settings.workspaceRow.working", "Agent Working")
        }
    }

    static func help(_ element: WorkspaceRowElement) -> SettingText? {
        switch element {
        case .icon: SettingsText.keyed("settings.workspaceRow.icon.help", "The icon or emoji you chose for a workspace.")
        case .process: SettingsText.keyed("settings.workspaceRow.process.help", "The terminal's title, which the shell or program sets.")
        case .agentStatus: SettingsText.keyed("settings.workspaceRow.agentStatus.help", "The status line agents and hooks report.")
        case .ports: SettingsText.keyed("settings.workspaceRow.ports.help", "Set by a hook: cmux workspace status set ports <text>.")
        case .pullRequest: SettingsText.keyed("settings.workspaceRow.pullRequest.help", "Set by a hook: cmux workspace status set pr <text>.")
        case .progress: SettingsText.keyed("settings.workspaceRow.progress.help", "A progress bar under the row and the busy mark of running work.")
        case .working: SettingsText.keyed("settings.workspaceRow.working.help", "A mark while an agent works in the workspace.")
        case .directory, .branch, .tabCount, .lastActivity: nil
        }
    }

    static func kindName(_ kind: WorkspaceRowKind) -> SettingText {
        switch kind {
        case .terminal: SettingsText.keyed("settings.workspaceRow.kind.terminal", "Terminal Workspaces")
        case .agent: SettingsText.keyed("settings.workspaceRow.kind.agent", "Agent Workspaces")
        case .browser: SettingsText.keyed("settings.workspaceRow.kind.browser", "Browser Workspaces")
        case .mixed: SettingsText.keyed("settings.workspaceRow.kind.mixed", "Mixed Workspaces")
        }
    }

    /// Every `sidebar.workspaceRow.*` key (agents may set them: looks only).
    static var keys: Set<String> { Set(descriptors().map(\.id)) }

    static var orderChoices: [SettingChoice] {
        WorkspaceRowElement.secondLine.map { SettingChoice($0.rawValue, title($0)) }
    }

    /// The Settings rows: one toggle per element and the order, shown on the
    /// page and in the palette; per-kind overrides are cmux.json and MDM only
    /// (44 rows would bury the page), so they stay off the page and palette.
    static func descriptors() -> [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.workspaceRows", "Workspace Rows")
        let defaults = WorkspaceRowElements.minimal
        var rows = WorkspaceRowElement.allCases.map { element in
            SettingDescriptor(path(element), section: .appearance, group: group, title: title(element), help: help(element),
                              kind: .toggle, default: .bool(defaults.shows(element)),
                              keywords: ["sidebar", "workspace", "row", element.rawValue])
        }
        rows.append(SettingDescriptor(
            orderPath(), section: .appearance, group: group,
            title: SettingsText.keyed("settings.workspaceRow.secondLineOrder", "Second Line Order"),
            help: SettingsText.keyed("settings.workspaceRow.secondLineOrder.help", "The order of the shown items under the workspace name."),
            kind: .orderedChoices(orderChoices), default: .array(WorkspaceRowElement.secondLine.map { .string($0.rawValue) }),
            keywords: ["sidebar", "workspace", "row", "order", "subtitle"]
        ))
        let sameAsAll = SettingsText.keyed("settings.workspaceRow.default.sameAsAll", "Same as All Workspaces")
        for kind in WorkspaceRowKind.allCases {
            let kindGroup = kindName(kind)
            for element in WorkspaceRowElement.allCases {
                rows.append(SettingDescriptor(path(element, kind: kind), section: .appearance, group: kindGroup, title: title(element),
                                              kind: .toggle, default: nil, defaultLabel: sameAsAll,
                                              keywords: ["sidebar", "workspace", "row", kind.rawValue, element.rawValue])
                    .hiddenFromSettingsPage("per-kind override: cmux.json only"))
            }
            rows.append(SettingDescriptor(orderPath(kind: kind), section: .appearance, group: kindGroup,
                                          title: SettingsText.keyed("settings.workspaceRow.secondLineOrder", "Second Line Order"),
                                          kind: .orderedChoices(orderChoices), default: nil, defaultLabel: sameAsAll,
                                          keywords: ["sidebar", "workspace", "row", kind.rawValue, "order"])
                .hiddenFromSettingsPage("per-kind override: cmux.json only"))
        }
        return rows
    }
}

extension SettingsController {
    /// Moves `sidebar.showWorkspaceDirectory` and `sidebar.showCounts` to
    /// their `sidebar.workspaceRow.*` keys in one atomic write, once at
    /// launch, so the file says what the sidebar draws. A set new key wins
    /// and the S1 key is dropped; a bad S1 value stays (with its diagnostic)
    /// until the user fixes it or writes the new toggle. Returns whether it
    /// wrote.
    @discardableResult
    public func migrateLegacyWorkspaceRowKeys() async throws -> Bool {
        var edits: [(path: [String], value: JSONValue?)] = []
        for element in WorkspaceRowElement.allCases {
            guard let legacy = WorkspaceRowSetting.legacyPaths[element], let old = try await file.value(at: legacy) else { continue }
            let path = WorkspaceRowSetting.path(element)
            if try await file.value(at: path) == nil {
                guard let on = old.boolValue else { continue }
                edits.append((path, .bool(on)))
            }
            edits.append((legacy, nil))
        }
        guard !edits.isEmpty else { return false }
        try await file.apply(edits)
        await reloadAfterWrite()
        return true
    }
}
