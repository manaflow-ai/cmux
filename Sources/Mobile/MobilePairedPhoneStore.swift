import CMUXMobileCore
import Foundation

/// The iOS application identity learned from one completed Mac pairing.
struct MobilePairedPhoneRecord: Codable, Equatable, Sendable {
    let clientID: String
    let bundleIdentifier: String
    let accountID: String?
    let pairedAt: Date
}

/// Owns the Mac's durable mapping from paired phone installs to iOS bundles.
///
/// The QR intentionally does not choose an iOS variant. A phone reports its
/// exact bundle after the authenticated host handshake, and this store keeps
/// that fact for push and paired-Mac backup routing. The old picker preference
/// is imported once as a compatibility fallback, then never participates in a
/// newly completed pairing.
@MainActor
final class MobilePairedPhoneStore {
    /// The serialized records written to the Mac's defaults domain.
    static let defaultsKey = "mobile.pairing.pairedPhoneRecords"
    /// The picker preference used by versions before handshake-owned routing.
    static let legacyDefaultsKey = "mobile.pairing.targetIOSBundleIdentifier"

    private static let legacyClientID = "legacy-picker-selection"
    private static let maximumRecordCount = 16
    private static let maximumClientIDLength = 200

    private let defaults: UserDefaults
    private let macInstanceTag: String
    private var recordsByClientID: [String: MobilePairedPhoneRecord]

    init(
        defaults: UserDefaults = .standard,
        macInstanceTag: String = MobileHostIdentity.instanceTag()
    ) {
        self.defaults = defaults
        self.macInstanceTag = macInstanceTag
        self.recordsByClientID = Self.decodeRecords(from: defaults)
        migrateLegacyPickerSelection()
    }

    /// Records the bundle that completed an authenticated pairing handshake.
    /// Invalid or empty identities are ignored so an untrusted payload cannot
    /// become a push namespace.
    @discardableResult
    func record(
        clientID: String,
        bundleIdentifier: String,
        accountID: String?,
        pairedAt: Date = Date()
    ) -> Bool {
        guard let normalizedClientID = Self.normalized(clientID),
              normalizedClientID.utf16.count <= Self.maximumClientIDLength,
              normalizedClientID != Self.legacyClientID,
              let normalizedBundleIdentifier = Self.validBundleIdentifier(bundleIdentifier),
              isBundleAllowedForMacLane(normalizedBundleIdentifier)
        else {
            return false
        }
        let normalizedAccountID = Self.normalized(accountID)
        if let existing = recordsByClientID[normalizedClientID],
           existing.bundleIdentifier == normalizedBundleIdentifier,
           existing.accountID == normalizedAccountID {
            return true
        }
        // A real handshake supersedes the pre-migration picker fallback. Once
        // the phone identity is known, the stale global value must not compete
        // with it after account or variant changes.
        let previousLegacyRecord = recordsByClientID.removeValue(
            forKey: Self.legacyClientID
        )
        let previousRecord = recordsByClientID[normalizedClientID]
        recordsByClientID[normalizedClientID] = MobilePairedPhoneRecord(
            clientID: normalizedClientID,
            bundleIdentifier: normalizedBundleIdentifier,
            accountID: normalizedAccountID,
            pairedAt: pairedAt
        )
        guard trimAndPersist() else {
            if let previousRecord {
                recordsByClientID[normalizedClientID] = previousRecord
            } else {
                recordsByClientID[normalizedClientID] = nil
            }
            if let previousLegacyRecord {
                recordsByClientID[Self.legacyClientID] = previousLegacyRecord
            }
            return false
        }
        return true
    }

    /// Resolves the iOS bundle for push and backup requests.
    ///
    /// A record for the current authenticated account wins over the migrated
    /// picker value. When no handshake record exists, the old value is retained
    /// as a one-time compatibility fallback; otherwise the Mac's lane-derived
    /// bundle preserves the pre-migration default behavior. If more than one
    /// install has paired, the newest completed handshake is authoritative for
    /// the Mac's single push and backup target.
    func targetBundleIdentifier(accountID: String?) -> String? {
        // Migrate lazily as well as at initialization. This covers a host that
        // starts before an older settings domain is loaded, and keeps migration
        // deterministic for an already-live singleton.
        migrateLegacyPickerSelection()
        let normalizedAccountID = Self.normalized(accountID)
        let candidates = recordsByClientID.values.filter { record in
            guard isBundleAllowedForMacLane(record.bundleIdentifier) else { return false }
            guard let recordAccountID = record.accountID else { return true }
            guard let normalizedAccountID else { return false }
            return recordAccountID == normalizedAccountID
        }
        if let latest = candidates.max(by: Self.recordsSortBefore) {
            return latest.bundleIdentifier
        }
        return fallbackBundleIdentifier
    }

    /// Returns a stable snapshot for diagnostics and behavior tests.
    var records: [MobilePairedPhoneRecord] {
        recordsByClientID.values.sorted(by: Self.recordsSortBefore)
    }

    private var fallbackBundleIdentifier: String? {
        let normalizedTag = macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTag.isEmpty || normalizedTag == "default" || normalizedTag == "nightly" {
            return "com.cmux.app"
        }
        return MobileIOSAppNamespace(
            pairedMacInstanceTag: macInstanceTag
        )?.bundleIdentifier
    }

    private var isOfficialMacLane: Bool {
        let normalizedTag = macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedTag.isEmpty || normalizedTag == "default" || normalizedTag == "nightly"
    }

    private func isBundleAllowedForMacLane(_ bundleIdentifier: String) -> Bool {
        if isOfficialMacLane {
            return [
                "com.cmux.app",
                "dev.cmux.app.beta",
                "dev.cmux.app.internal",
                "dev.cmux.app.demo",
            ].contains(bundleIdentifier)
        }
        return bundleIdentifier == fallbackBundleIdentifier
    }
}

private extension MobilePairedPhoneStore {
    static func decodeRecords(from defaults: UserDefaults) -> [String: MobilePairedPhoneRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                  [MobilePairedPhoneRecord].self,
                  from: data
              ) else {
            return [:]
        }
        return decoded.reduce(into: [:]) { records, record in
            guard let clientID = normalized(record.clientID),
                  clientID.utf16.count <= maximumClientIDLength,
                  validBundleIdentifier(record.bundleIdentifier) != nil else {
                return
            }
            records[clientID] = MobilePairedPhoneRecord(
                clientID: clientID,
                bundleIdentifier: record.bundleIdentifier,
                accountID: normalized(record.accountID),
                pairedAt: record.pairedAt
            )
        }
    }

    func migrateLegacyPickerSelection() {
        guard let rawLegacyValue = defaults.string(forKey: Self.legacyDefaultsKey) else {
            return
        }
        if let bundleIdentifier = Self.validBundleIdentifier(rawLegacyValue),
           isBundleAllowedForMacLane(bundleIdentifier) {
            recordsByClientID[Self.legacyClientID] = MobilePairedPhoneRecord(
                clientID: Self.legacyClientID,
                bundleIdentifier: bundleIdentifier,
                accountID: nil,
                pairedAt: .distantPast
            )
            guard trimAndPersist() else { return }
        }
        // Even an invalid stale value should not remain a hidden routing input.
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    @discardableResult
    func trimAndPersist() -> Bool {
        let retained = recordsByClientID.values
            .sorted(by: Self.recordsSortBefore)
            .suffix(Self.maximumRecordCount)
        recordsByClientID = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.clientID, $0) }
        )
        guard let data = try? JSONEncoder().encode(Array(retained)) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }

    static func recordsSortBefore(
        _ lhs: MobilePairedPhoneRecord,
        _ rhs: MobilePairedPhoneRecord
    ) -> Bool {
        if lhs.pairedAt != rhs.pairedAt {
            return lhs.pairedAt < rhs.pairedAt
        }
        return lhs.clientID < rhs.clientID
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func validBundleIdentifier(_ value: String?) -> String? {
        guard let normalized = normalized(value),
              let namespace = MobileIOSAppNamespace(bundleIdentifier: normalized),
              CmxPairingURLScheme(iOSBundleIdentifier: namespace.bundleIdentifier) != nil
        else {
            return nil
        }
        return namespace.bundleIdentifier
    }
}
