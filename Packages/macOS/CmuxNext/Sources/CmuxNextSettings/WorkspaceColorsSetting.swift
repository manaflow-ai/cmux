public import CmuxNextDesign

/// `workspaceColors.indicatorStyle` (#25653): the key classic reads for the same choice, so one
/// cmux.json colors rows the same way in both apps (classic's `solidFill` reads as `fill`).
public nonisolated struct WorkspaceColorsSetting {
    public nonisolated init() {}

    static func parseIndicatorStyle(_ root: JSONValue, fallback: WorkspaceColorIndicatorStyle,
                                    _ diagnostics: inout [SettingsDiagnostic]) -> WorkspaceColorIndicatorStyle {
        guard let value = root.value(at: indicatorStylePath) else { return fallback }
        guard let text = value.stringValue, let style = WorkspaceColorIndicatorStyle(setting: text) else {
            let choices = WorkspaceColorIndicatorStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: indicatorStylePath.joined(separator: "."),
                                                  message: "expected one of " + choices))
            return fallback
        }
        return style
    }
}
