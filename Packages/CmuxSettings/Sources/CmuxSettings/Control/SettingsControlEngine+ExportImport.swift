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

        // Phase 2 — apply the fully-validated set, snapshotting each setting
        // first so a mid-apply backend write failure (e.g. cmux.json became
        // unwritable) rolls back the changes already made, preserving the
        // all-or-nothing contract. Secret writes cannot be rolled back (the
        // plaintext is never read back); they are extremely rare in an import
        // (redaction markers are skipped in phase 1) and are left as applied.
        var applied: [(descriptor: CatalogSettingDescriptor, previousValue: SettingJSONValue, wasOverridden: Bool)] = []
        for entry in validated {
            let previousValue = await entry.descriptor.currentValue(in: stores)
            let wasOverridden = await entry.descriptor.isOverridden(in: stores)
            do {
                try await entry.descriptor.applyNormalized(entry.value, in: stores)
                applied.append((entry.descriptor, previousValue, wasOverridden))
            } catch {
                await rollBack(applied)
                throw SettingsControlError.importFailed(errors: [
                    "failed to apply '\(entry.descriptor.id)': \(error.localizedDescription) — rolled back \(applied.count) earlier change(s)",
                ])
            }
        }
    }

    /// Best-effort restore of already-applied entries in reverse order: a setting
    /// that was overridden is restored to its prior value; one that was at its
    /// default is cleared. Secret-backed entries are skipped (their plaintext was
    /// never read).
    private func rollBack(
        _ applied: [(descriptor: CatalogSettingDescriptor, previousValue: SettingJSONValue, wasOverridden: Bool)]
    ) async {
        for entry in applied.reversed() where !entry.descriptor.isSecret {
            if entry.wasOverridden {
                try? await entry.descriptor.applyNormalized(entry.previousValue, in: stores)
            } else {
                try? await entry.descriptor.reset(in: stores)
            }
        }
    }
}
