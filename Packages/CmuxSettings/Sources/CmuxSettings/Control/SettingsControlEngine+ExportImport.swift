import Foundation

extension SettingsControlEngine {
    /// Snapshots current settings into a portable document.
    ///
    /// Secret-backed settings are omitted so the export never carries a
    /// credential. When `includeDefaults` is `false`, only overridden settings
    /// are emitted (a minimal, version-control-friendly profile); otherwise the
    /// full current state of every non-secret setting is captured.
    public func export(includeDefaults: Bool = true) async -> SettingsDocument {
        var settings: [String: SettingJSONValue] = [:]
        for descriptor in descriptors where !descriptor.isSecret {
            if !includeDefaults {
                let overridden = await descriptor.isOverridden(in: stores)
                guard overridden else { continue }
            }
            settings[descriptor.id] = await descriptor.currentValue(in: stores)
        }
        return SettingsDocument(settings: settings)
    }

    /// Applies an export document atomically: every entry is validated first and
    /// the whole import is rejected (with one message per offending entry, and
    /// **no** writes) if any entry is unknown or invalid. Only after the entire
    /// document validates are the writes performed.
    ///
    /// Redacted secret placeholders are skipped rather than written, so
    /// re-importing an export does not clobber a real secret with `<redacted>`.
    public func importDocument(_ document: SettingsDocument) async throws {
        // Phase 1 — validate everything, accumulate errors, touch nothing.
        var validated: [(descriptor: CatalogSettingDescriptor, value: SettingJSONValue)] = []
        var errors: [String] = []

        for (id, value) in document.settings.sorted(by: { $0.key < $1.key }) {
            guard let descriptor = descriptorsByID[id] else {
                errors.append("unknown setting '\(id)'")
                continue
            }
            if descriptor.isSecret, case let .string(text) = value, text == CatalogSettingDescriptor.redactionMarker {
                // A redacted placeholder carries no real secret; leave the
                // stored secret untouched.
                continue
            }
            do {
                let normalized = try descriptor.validate(value)
                validated.append((descriptor, normalized))
            } catch let error as SettingsControlError {
                errors.append(error.message)
            } catch {
                errors.append("\(id): \(error.localizedDescription)")
            }
        }

        guard errors.isEmpty else {
            throw SettingsControlError.importFailed(errors: errors)
        }

        // Phase 2 — apply the fully-validated set.
        for entry in validated {
            try await entry.descriptor.applyNormalized(entry.value, in: stores)
        }
    }
}
