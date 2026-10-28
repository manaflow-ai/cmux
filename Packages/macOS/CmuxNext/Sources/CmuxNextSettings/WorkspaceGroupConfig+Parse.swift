import CmuxNextDesignTokens

nonisolated extension WorkspaceGroupConfig {
    /// `workspaceGroups` from the file. A missing key is the default with no diagnostic; a bad
    /// value is dropped (the rest of its entry stays) with a diagnostic naming it.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> WorkspaceGroupConfig {
        var config = WorkspaceGroupConfig()
        guard let value = root.value(at: configPath) else { return config }
        guard let object = value.objectValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: dotted(configPath), message: "expected an object"))
            return config
        }
        if let raw = object["newWorkspacePlacement"] {
            let path = dotted(configPath + ["newWorkspacePlacement"])
            if let placement = placement(raw, path: path, diagnostics: &diagnostics) { config.newWorkspacePlacement = placement }
        }
        guard let entries = object["byCwd"] else { return config }
        guard let byCwd = entries.objectValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: dotted(byCwdPath), message: "expected an object of folder to group settings"))
            return config
        }
        for (key, raw) in byCwd {
            let path = dotted(byCwdPath) + "." + key
            guard let fields = raw.objectValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an object"))
                continue
            }
            config.byCwd[key] = entry(fields, path: path, diagnostics: &diagnostics)
        }
        return config
    }

    private static func entry(_ fields: [String: JSONValue], path: String, diagnostics: inout [SettingsDiagnostic]) -> Entry {
        var entry = Entry()
        if let raw = fields["color"] {
            if let wire = raw.stringValue, let tint = GroupTint(wire: wire) { entry.color = tint } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path + ".color", message: "expected a group color or #RRGGBB"))
            }
        }
        if let raw = fields["icon"] {
            if let icon = raw.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty { entry.icon = icon } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path + ".icon", message: "expected a symbol name or an emoji"))
            }
        }
        if let raw = fields["newWorkspacePlacement"] {
            entry.newWorkspacePlacement = placement(raw, path: path + ".newWorkspacePlacement", diagnostics: &diagnostics)
        }
        if let raw = fields["contextMenu"] {
            guard let rows = raw.arrayValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path + ".contextMenu", message: "expected a list of {\"action\": ...}"))
                return entry
            }
            for (index, row) in rows.enumerated() {
                guard let action = row.objectValue?["action"]?.stringValue, !action.isEmpty else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path + ".contextMenu.\(index)", message: "expected an action"))
                    continue
                }
                let title = row.objectValue?["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                entry.contextMenu.append(MenuEntry(action: action, title: title))
            }
        }
        return entry
    }

    private static func placement(_ raw: JSONValue, path: String, diagnostics: inout [SettingsDiagnostic]) -> Placement? {
        if let text = raw.stringValue, let placement = Placement(rawValue: text) { return placement }
        let allowed = Placement.allCases.map(\.rawValue).joined(separator: ", ")
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected one of \(allowed)"))
        return nil
    }

    private static func dotted(_ path: [String]) -> String { path.joined(separator: ".") }
}
