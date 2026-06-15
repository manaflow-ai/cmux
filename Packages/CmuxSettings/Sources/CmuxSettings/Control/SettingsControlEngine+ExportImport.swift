import Foundation

extension SettingsControlEngine {
    /// Snapshots current settings into a portable document.
    ///
    /// Secret-backed settings are omitted so the export never carries a
    /// credential. By default only **overridden** settings are emitted — a
    /// minimal, version-control-friendly profile that also avoids serializing
    /// catalog defaults whose JSON shape can differ from the runtime schema
    /// (e.g. `notifications.hooks`), which an import would otherwise re-apply.
    /// Pass `includeDefaults: true` to capture the full current state.
    public func export(includeDefaults: Bool = false) async -> SettingsDocument {
        var settings: [String: SettingJSONValue] = [:]
        for descriptor in descriptors where !descriptor.isSecret {
            if !includeDefaults {
                let overridden = await descriptor.isOverridden(in: stores)
                guard overridden else { continue }
            }
            let value = await descriptor.currentValue(in: stores)
            // Skip a JSON-backed setting whose catalog type cannot faithfully
            // represent what is actually in cmux.json (e.g. notifications.hooks is
            // stored as an array but cataloged as a dictionary, so the typed read
            // falls back to the default). Exporting the misdecoded value would
            // clobber the user's real value on import.
            if descriptor.backend == .json,
               let raw = await stores.json.rawSettingJSON(atDottedPath: descriptor.id),
               raw != value {
                continue
            }
            settings[descriptor.id] = value
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
            if descriptor.isSecret {
                // Import never writes secrets: export omits them, and a secret
                // write cannot be rolled back if a later entry fails, so a failed
                // import must never have rotated a credential. Set secrets
                // explicitly with `cmux settings set` instead.
                continue
            }
            // A setting managed in cmux.json is re-applied on reload, so importing
            // it to UserDefaults would be a silent no-op — reject up front (the
            // same guard `set`/`unset` apply), keeping import all-or-nothing.
            if descriptor.backend != .json, await stores.json.hasRawValue(atDottedPath: descriptor.id) {
                errors.append(SettingsControlError.managedInJSON(key: id).message)
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
                let restored = await rollBack(applied)
                var message = "failed to apply '\(entry.descriptor.id)': \(error.localizedDescription)"
                if !applied.isEmpty {
                    message += "; rolled back \(restored) of \(applied.count) earlier change(s)"
                    if restored < applied.count {
                        message += " (the rest could not be restored — check ~/.config/cmux/cmux.json)"
                    }
                }
                throw SettingsControlError.importFailed(errors: [message])
            }
        }
    }

    /// Best-effort restore of already-applied entries in reverse order: a setting
    /// that was overridden is restored to its prior value; one that was at its
    /// default is cleared. Secret-backed entries are skipped (their plaintext was
    /// never read). Returns the number of entries actually restored so the caller
    /// never overclaims a full rollback when a restore itself fails (likely under
    /// the same unwritable-`cmux.json` condition that triggered the rollback).
    private func rollBack(
        _ applied: [(descriptor: CatalogSettingDescriptor, previousValue: SettingJSONValue, wasOverridden: Bool)]
    ) async -> Int {
        var restored = 0
        for entry in applied.reversed() where !entry.descriptor.isSecret {
            do {
                if entry.wasOverridden {
                    try await entry.descriptor.applyNormalized(entry.previousValue, in: stores)
                } else {
                    try await entry.descriptor.reset(in: stores)
                }
                restored += 1
            } catch {
                // Best-effort: a failed restore is reflected in the returned count.
            }
        }
        return restored
    }
}
