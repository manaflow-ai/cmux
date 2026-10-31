public import CmuxNextSettings

nonisolated extension AppJSON {
    /// Settings/control JSON to app JSON.
    public init(_ value: CmuxNextSettings.JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let v): self = .bool(v)
        case .number(let v): self = .number(v)
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map(AppJSON.init))
        case .object(let v): self = .object(v.mapValues(AppJSON.init))
        }
    }

    public var settingsValue: CmuxNextSettings.JSONValue {
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
