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

    public init() {}

    public static func path(_ element: WorkspaceRowElement, kind: WorkspaceRowKind? = nil) -> [String] {
        root + (kind.map { [$0.rawValue] } ?? []) + [element.rawValue]
    }

    public static func orderPath(kind: WorkspaceRowKind? = nil) -> [String] {
        root + (kind.map { [$0.rawValue] } ?? []) + [orderKey]
    }

    public func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> WorkspaceRowPreferences {
        var shown = Set(WorkspaceRowElement.allCases.filter(Self.fallback))
        for element in WorkspaceRowElement.allCases {
            var path = Self.path(element)
            if root.value(at: path) == nil, let legacy = Self.legacyPaths[element], root.value(at: legacy) != nil { path = legacy }
            guard let on = flag(root, path, &diagnostics) else { continue }
            if on { shown.insert(element) } else { shown.remove(element) }
        }
        let order = self.order(root, Self.orderPath(), &diagnostics) ?? Self.secondLineOrderDefault.compactMap(WorkspaceRowElement.init(rawValue:))
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
    /// The rows, generated from schemas/settings/source/sidebar.json: one toggle per element and
    /// the order, shown on the page and in the palette; per-kind overrides are cmux.json and MDM
    /// only (56 rows would bury the page), so they stay off the page and palette.
    static var descriptors: [SettingDescriptor] {
        SidebarSettingsSchema.workspaceRows + SidebarSettingsSchema.terminalWorkspaceRows + SidebarSettingsSchema.agentWorkspaceRows
            + SidebarSettingsSchema.browserWorkspaceRows + SidebarSettingsSchema.mixedWorkspaceRows
    }

    /// Whether `element` shows when its `sidebar.workspaceRow.<element>` key is unset.
    static func fallback(_ element: WorkspaceRowElement) -> Bool {
        switch element {
        case .icon: iconDefault
        case .directory: directoryDefault
        case .branch: branchDefault
        case .process: processDefault
        case .agentStatus: agentStatusDefault
        case .tabCount: tabCountDefault
        case .ports: portsDefault
        case .lastActivity: lastActivityDefault
        case .pullRequest: pullRequestDefault
        case .progress: progressDefault
        case .working: workingDefault
        case .log: logDefault
        case .notification: notificationDefault
        }
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
