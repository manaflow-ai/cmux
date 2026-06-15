import Foundation

/// The catalog-driven brain behind `cmux settings`.
///
/// Every operation iterates ``SettingCatalog`` via ``CatalogSettingDescriptor``
/// and routes each read/write to the correct backend. There is **no
/// per-setting code**: type and enum validation come from catalog metadata, so
/// a setting added to a `*CatalogSection` is reachable here the moment its key
/// exists. The engine is the unit-testable core — the app constructs it with
/// live stores (so writes apply live, exactly as the Settings UI does), while
/// tests construct it with an isolated suite + temp files.
public struct SettingsControlEngine: Sendable {
    /// The backends reads and writes route through.
    public let stores: SettingsControlStores

    let catalog: SettingCatalog
    let descriptors: [CatalogSettingDescriptor]
    let descriptorsByID: [String: CatalogSettingDescriptor]

    public init(stores: SettingsControlStores, catalog: SettingCatalog = SettingCatalog()) {
        self.stores = stores
        self.catalog = catalog
        // Stable, sorted enumeration so list/export output is deterministic.
        let sorted = catalog.allDescriptors.sorted { $0.id < $1.id }
        self.descriptors = sorted
        self.descriptorsByID = Dictionary(sorted.map { ($0.id, $0) }) { first, _ in first }
    }

    /// Every setting id, sorted. Backs `list --keys` and the parity test.
    public var settingIDs: [String] { descriptors.map(\.id) }

    /// Looks up a descriptor or throws ``SettingsControlError/unknownKey(_:)``.
    func descriptor(for id: String) throws -> CatalogSettingDescriptor {
        guard let descriptor = descriptorsByID[id] else {
            throw SettingsControlError.unknownKey(id)
        }
        return descriptor
    }

    // MARK: - Read

    /// Every setting as a row, sorted by id.
    public func list() async -> [SettingRow] {
        var rows: [SettingRow] = []
        rows.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            rows.append(await row(for: descriptor))
        }
        return rows
    }

    /// One setting as a row. Throws on unknown key.
    public func get(_ id: String) async throws -> SettingRow {
        await row(for: try descriptor(for: id))
    }

    /// Full metadata for one setting. Throws on unknown key.
    public func describe(_ id: String) async throws -> SettingDescription {
        let descriptor = try descriptor(for: id)
        let value = await descriptor.currentValue(in: stores)
        let overridden = await descriptor.isOverridden(in: stores)
        return SettingDescription(
            id: descriptor.id,
            backend: descriptor.backend,
            type: descriptor.valueType.name,
            allowedValues: descriptor.valueType.enumCases,
            isSecret: descriptor.isSecret,
            value: value,
            defaultValue: descriptor.defaultValue,
            isOverridden: overridden,
            section: Self.section(of: descriptor.id)
        )
    }

    private func row(for descriptor: CatalogSettingDescriptor) async -> SettingRow {
        let value = await descriptor.currentValue(in: stores)
        let overridden = await descriptor.isOverridden(in: stores)
        return SettingRow(
            id: descriptor.id,
            backend: descriptor.backend,
            valueType: descriptor.valueType,
            isSecret: descriptor.isSecret,
            value: value,
            defaultValue: descriptor.defaultValue,
            isOverridden: overridden
        )
    }

    // MARK: - Write

    /// Validates and writes a raw command-line value. Returns the resulting row.
    /// Throws ``SettingsControlError`` on unknown key or invalid value; never a
    /// silent no-op.
    @discardableResult
    public func set(_ id: String, rawValue: String) async throws -> SettingRow {
        let descriptor = try descriptor(for: id)
        let candidate = try parseRawValue(rawValue, for: descriptor)
        try await descriptor.set(candidate, in: stores)
        return await row(for: descriptor)
    }

    /// Validates and writes a JSON-typed value (as opposed to a raw CLI string).
    /// Used by the import path and the socket layer, which already carry typed
    /// JSON. Returns the resulting row.
    @discardableResult
    public func setValue(_ id: String, value: SettingJSONValue) async throws -> SettingRow {
        let descriptor = try descriptor(for: id)
        try await descriptor.set(value, in: stores)
        return await row(for: descriptor)
    }

    /// Clears a setting's override, reverting to its default. Returns the
    /// resulting (default) row.
    @discardableResult
    public func unset(_ id: String) async throws -> SettingRow {
        let descriptor = try descriptor(for: id)
        try await descriptor.reset(in: stores)
        return await row(for: descriptor)
    }

    /// Alias of ``unset(_:)`` for the `reset <key>` spelling.
    @discardableResult
    public func reset(_ id: String) async throws -> SettingRow {
        try await unset(id)
    }

    /// Clears every override, reverting the whole catalog to defaults. Best-effort
    /// across backends: UserDefaults overrides are dropped in one batch, then
    /// JSON and secret overrides are cleared.
    public func resetAll() async throws {
        await stores.defaults.resetAll(catalog.all)
        for descriptor in descriptors where descriptor.backend != .userDefaults {
            try await descriptor.reset(in: stores)
        }
    }

    // MARK: - Raw value parsing (type-directed)

    /// Turns a raw command-line argument into a candidate value, directed by the
    /// setting's type so `dark`, `9100`, `0.5`, `true`, and `["a","b"]` all work
    /// without the user having to JSON-quote scalars.
    func parseRawValue(_ raw: String, for descriptor: CatalogSettingDescriptor) throws -> SettingJSONValue {
        switch descriptor.valueType {
        case .string, .enumeration:
            // Literal text. Enum membership and any string constraints are
            // enforced by the descriptor's validator.
            return .string(raw)
        case .bool:
            guard let bool = Self.parseBool(raw) else {
                throw SettingsControlError.invalidValue(
                    key: descriptor.id,
                    reason: "expected a boolean (true/false), got '\(raw)'"
                )
            }
            return .bool(bool)
        case .int:
            guard let int = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                throw SettingsControlError.invalidValue(
                    key: descriptor.id,
                    reason: "expected an integer, got '\(raw)'"
                )
            }
            return .int(int)
        case .double:
            // Reject non-finite spellings (`nan`, `inf`): they are not valid JSON
            // and would break the socket response / `--json` / export after being
            // written, matching the config-file path's finite-number rule.
            guard let double = Double(raw.trimmingCharacters(in: .whitespaces)), double.isFinite else {
                throw SettingsControlError.invalidValue(
                    key: descriptor.id,
                    reason: "expected a finite number, got '\(raw)'"
                )
            }
            return .double(double)
        case .json:
            return SettingJSONValue.parseJSON(raw)
        }
    }

    static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    /// The catalog section a setting belongs to (its dotted-id prefix).
    static func section(of id: String) -> String {
        id.split(separator: ".").first.map(String.init) ?? id
    }
}
