import Foundation

/// A type-erased, fully self-describing view onto one catalog setting.
///
/// ``AnySettingKey`` erases a key down to `id` + backend `Kind`, which is enough
/// for migration but not for a CLI: it cannot read the current value, validate a
/// new one against the key's `Value` type, or report the enum cases. This
/// descriptor closes that gap. Each flavor's initializer captures the key's
/// static `Value` in a set of `@Sendable` closures (exactly the pattern
/// ``AnySettingKey`` uses for `migrateUserDefaultsLegacyKeys`), so the engine can
/// read / validate / write / reset / describe **every** setting generically —
/// with no per-setting code.
///
/// Because descriptors are derived by reflection over ``SettingCatalog`` (see
/// ``SettingCatalogSection/allDescriptors``), a setting added to a
/// `*CatalogSection` automatically becomes reachable from `list` / `get` /
/// `set` / `describe` / `reset` / `export` — the auto-extension guarantee the
/// parity test enforces.
public struct CatalogSettingDescriptor: Sendable {
    /// The dotted identifier (e.g. `app.appearance`).
    public let id: String
    /// Where the value persists.
    public let backend: SettingBackend
    /// The value's shape, derived from its static `Value` type.
    public let valueType: SettingValueType
    /// Whether the value is a secret (redacted on read; writable).
    public let isSecret: Bool
    /// The key's default, as a value-typed JSON value.
    public let defaultValue: SettingJSONValue

    /// Reads the current value. For secrets this returns a redaction marker (or
    /// the empty default when unset) and never the plaintext.
    let readCurrent: @Sendable (SettingsControlStores) async -> SettingJSONValue
    /// Whether a stored override exists (vs. falling back to the default).
    let readHasOverride: @Sendable (SettingsControlStores) async -> Bool
    /// Validates a candidate value against the key's `Value` type, returning the
    /// canonical normalized value or `nil` when it does not decode.
    let validateValue: @Sendable (SettingJSONValue) -> SettingJSONValue?
    /// Writes a (previously validated) value to the backend.
    let applyValue: @Sendable (SettingsControlStores, SettingJSONValue) async throws -> Void
    /// Clears the override, reverting to the default.
    let clearValue: @Sendable (SettingsControlStores) async throws -> Void

    /// Reads and value-types the current value.
    public func currentValue(in stores: SettingsControlStores) async -> SettingJSONValue {
        await readCurrent(stores)
    }

    /// Whether a stored override exists for the key.
    public func isOverridden(in stores: SettingsControlStores) async -> Bool {
        await readHasOverride(stores)
    }

    /// Validates a candidate value, returning the normalized form or throwing
    /// ``SettingsControlError/invalidValue(key:reason:)``.
    public func validate(_ candidate: SettingJSONValue) throws -> SettingJSONValue {
        guard let normalized = validateValue(candidate) else {
            throw SettingsControlError.invalidValue(key: id, reason: invalidValueReason(candidate))
        }
        return normalized
    }

    /// Validates then writes `candidate`.
    public func set(_ candidate: SettingJSONValue, in stores: SettingsControlStores) async throws {
        let normalized = try validate(candidate)
        try await applyValue(stores, normalized)
    }

    /// Writes an already-validated value. Used by `import`'s second phase, after
    /// every entry has passed validation, so the apply step performs no further
    /// checks (the all-or-nothing guarantee is enforced up front).
    func applyNormalized(_ normalized: SettingJSONValue, in stores: SettingsControlStores) async throws {
        try await applyValue(stores, normalized)
    }

    /// Clears the override.
    public func reset(in stores: SettingsControlStores) async throws {
        try await clearValue(stores)
    }

    private func invalidValueReason(_ candidate: SettingJSONValue) -> String {
        switch valueType {
        case let .enumeration(cases):
            return "expected one of [\(cases.joined(separator: ", "))], got \(candidate.displayString)"
        case .bool:
            return "expected a boolean (true/false)"
        case .int:
            return "expected an integer"
        case .double:
            return "expected a number"
        case .string:
            return "expected a string"
        case .json:
            return "expected valid JSON for this setting"
        }
    }
}

extension CatalogSettingDescriptor {
    /// Derives the value shape from the static `Value` type. Enumerations are
    /// detected via ``SettingCodable/settingAllowedRawValues`` (so any
    /// `CaseIterable & RawRepresentable` enum is recognized automatically);
    /// everything else falls back to scalar identity, then `json` for
    /// collections and structured values.
    static func valueType<Value: SettingCodable>(for _: Value.Type) -> SettingValueType {
        if let cases = Value.settingAllowedRawValues {
            return .enumeration(cases: cases)
        }
        if Value.self == Bool.self { return .bool }
        if Value.self == Int.self { return .int }
        if Value.self == Double.self { return .double }
        if Value.self == String.self { return .string }
        return .json
    }

    /// Wraps a `UserDefaults`-backed key.
    init<Value: SettingCodable>(defaultsKey key: DefaultsKey<Value>) {
        self.id = key.id
        self.backend = .userDefaults
        self.isSecret = false
        self.valueType = Self.valueType(for: Value.self)
        self.defaultValue = SettingJSONValue(jsonObject: key.defaultValue.encodeForJSON())
        self.readCurrent = { stores in
            let value = await stores.defaults.value(for: key)
            return SettingJSONValue(jsonObject: value.encodeForJSON())
        }
        self.readHasOverride = { stores in
            await stores.defaults.hasOverride(for: key)
        }
        self.validateValue = { candidate in
            guard let decoded = Value.decodeFromJSON(candidate.jsonObject) else { return nil }
            return SettingJSONValue(jsonObject: decoded.encodeForJSON())
        }
        self.applyValue = { stores, candidate in
            guard let decoded = Value.decodeFromJSON(candidate.jsonObject) else {
                throw SettingsControlError.invalidValue(key: key.id, reason: "value did not decode")
            }
            await stores.defaults.set(decoded, for: key)
        }
        self.clearValue = { stores in
            await stores.defaults.reset(key)
        }
    }

    /// Wraps a `cmux.json`-backed key.
    init<Value: SettingCodable>(jsonKey key: JSONKey<Value>) {
        self.id = key.id
        self.backend = .json
        self.isSecret = false
        self.valueType = Self.valueType(for: Value.self)
        self.defaultValue = SettingJSONValue(jsonObject: key.defaultValue.encodeForJSON())
        self.readCurrent = { stores in
            let value = await stores.json.value(for: key)
            return SettingJSONValue(jsonObject: value.encodeForJSON())
        }
        self.readHasOverride = { stores in
            await stores.json.hasValue(for: key)
        }
        self.validateValue = { candidate in
            guard let decoded = Value.decodeFromJSON(candidate.jsonObject) else { return nil }
            return SettingJSONValue(jsonObject: decoded.encodeForJSON())
        }
        self.applyValue = { stores, candidate in
            guard let decoded = Value.decodeFromJSON(candidate.jsonObject) else {
                throw SettingsControlError.invalidValue(key: key.id, reason: "value did not decode")
            }
            do {
                try await stores.json.set(decoded, for: key)
            } catch {
                throw SettingsControlError.storage("failed to write '\(key.id)' to cmux.json: \(error.localizedDescription)")
            }
        }
        self.clearValue = { stores in
            do {
                try await stores.json.reset(key)
            } catch {
                throw SettingsControlError.storage("failed to clear '\(key.id)' in cmux.json: \(error.localizedDescription)")
            }
        }
    }

    /// Wraps a secret-file-backed key. The plaintext is never read for output —
    /// ``currentValue(in:)`` reports a redaction marker when present.
    init(secretKey key: SecretFileKey) {
        self.id = key.id
        self.backend = .secret
        self.isSecret = true
        self.valueType = .string
        self.defaultValue = .string(key.defaultValue)
        self.readCurrent = { stores in
            let present = await stores.secret.hasValue(for: key)
            return .string(present ? SettingsRedaction.marker : key.defaultValue)
        }
        self.readHasOverride = { stores in
            await stores.secret.hasValue(for: key)
        }
        self.validateValue = { candidate in
            // Secrets are plain strings. Accept any scalar by stringifying its
            // display form; reject structured JSON.
            switch candidate {
            case let .string(value): return .string(value)
            case .bool, .int, .double: return .string(candidate.displayString)
            case .null, .array, .object: return nil
            }
        }
        self.applyValue = { stores, candidate in
            guard case let .string(value) = candidate else {
                throw SettingsControlError.invalidValue(key: key.id, reason: "secret must be a string")
            }
            do {
                try await stores.secret.set(value, for: key)
            } catch {
                throw SettingsControlError.storage("failed to write secret '\(key.id)': \(error.localizedDescription)")
            }
        }
        self.clearValue = { stores in
            do {
                try await stores.secret.reset(key)
            } catch {
                throw SettingsControlError.storage("failed to clear secret '\(key.id)': \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Catalog reflection

/// Internal bridge so ``SettingCatalogSection/allDescriptors`` can build a
/// descriptor from a reflected key while its static `Value` is still known.
/// Mirrors ``AnySettingKeyConvertible``.
protocol CatalogDescriptorConvertible {
    var asCatalogDescriptor: CatalogSettingDescriptor { get }
}

extension DefaultsKey: CatalogDescriptorConvertible {
    var asCatalogDescriptor: CatalogSettingDescriptor { CatalogSettingDescriptor(defaultsKey: self) }
}

extension JSONKey: CatalogDescriptorConvertible {
    var asCatalogDescriptor: CatalogSettingDescriptor { CatalogSettingDescriptor(jsonKey: self) }
}

extension SecretFileKey: CatalogDescriptorConvertible {
    var asCatalogDescriptor: CatalogSettingDescriptor { CatalogSettingDescriptor(secretKey: self) }
}

extension SettingCatalogSection {
    /// Every setting in this section and nested sections, as full descriptors.
    ///
    /// Derived by the same `Mirror` walk as ``all``, but producing the richer
    /// ``CatalogSettingDescriptor`` instead of ``AnySettingKey``. This is the
    /// single enumeration the settings control engine iterates, so it stays in
    /// lockstep with the catalog by construction.
    public var allDescriptors: [CatalogSettingDescriptor] {
        Mirror(reflecting: self).children.flatMap { _, value -> [CatalogSettingDescriptor] in
            if let key = value as? CatalogDescriptorConvertible {
                return [key.asCatalogDescriptor]
            }
            if let section = value as? SettingCatalogSection {
                return section.allDescriptors
            }
            return []
        }
    }
}
