public import CmuxNextSettings

/// Bridges between app JSON and Settings/control JSON (the same shapes).
public nonisolated extension AppJSON {
    /// Converts Settings/control JSON to app JSON.
    /// - Parameter value: A Settings or control-router JSON value.
    init(_ value: CmuxNextSettings.JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let v): self = .bool(v)
        case .number(let v): self = .number(v)
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map(AppJSON.init))
        case .object(let v): self = .object(v.mapValues(AppJSON.init))
        }
    }

    /// This value as Settings/control JSON.
    var settingsValue: CmuxNextSettings.JSONValue {
        switch self {
        case .null: .null
        case .bool(let v): .bool(v)
        case .number(let v): .number(v)
        case .string(let v): .string(v)
        case .array(let v): .array(v.map(\.settingsValue))
        case .object(let v): .object(v.mapValues(\.settingsValue))
        }
    }
}
