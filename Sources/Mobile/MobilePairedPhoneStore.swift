import CMUXMobileCore
import Foundation

/// Owns the Mac's durable mapping from paired phone installs to iOS bundles.
///
/// The QR intentionally does not choose an iOS variant. A phone reports its
/// exact bundle after the authenticated host handshake, and this store keeps
/// that fact for push and paired-Mac backup routing. The old picker preference
/// is imported once as a migration marker, but only an authenticated handshake
/// record can ever be selected for runtime routing.
@MainActor
final class MobilePairedPhoneStore {
    /// The serialized records written to the Mac's defaults domain.
    static let defaultsKey = "mobile.pairing.pairedPhoneRecords"
    /// The picker preference used by versions before handshake-owned routing.
    static let legacyDefaultsKey = "mobile.pairing.targetIOSBundleIdentifier"

    private static let legacyClientID = "legacy-picker-selection"
    private static let maximumRecordCount = 16
    private static let maximumClientIDLength = 200
    private static let maximumHandshakeIdentityLength = 512

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
        handshakeIdentity: String? = nil,
        trustedIOSBuildTag: String? = nil,
        pairedAt: Date = .now
    ) -> Bool {
        guard let normalizedClientID = Self.normalized(clientID),
              normalizedClientID.utf16.count <= Self.maximumClientIDLength,
              normalizedClientID != Self.legacyClientID,
              let normalizedBundleIdentifier = Self.validBundleIdentifier(bundleIdentifier),
              isBundleAllowedForMacLane(
                  normalizedBundleIdentifier,
                  trustedIOSBuildTag: trustedIOSBuildTag
              )
        else {
            return false
        }
        guard let normalizedAccountID = Self.normalized(accountID),
              let normalizedHandshakeIdentity = Self.normalized(handshakeIdentity),
              normalizedHandshakeIdentity.utf8.count <= Self.maximumHandshakeIdentityLength
        else {
            return false
        }
        if let existing = recordsByClientID[normalizedClientID],
           existing.source == .authenticatedHandshake,
           existing.accountID == normalizedAccountID,
           existing.handshakeIdentity == normalizedHandshakeIdentity,
           existing.bundleIdentifier == normalizedBundleIdentifier {
            // Host-status heartbeats repeat the same authenticated identity.
            // Treat them as a read so pairedAt, defaults, and downstream
            // re-key notifications stay stable until a new transport pairs.
            return false
        }
        if let existing = recordsByClientID[normalizedClientID],
           existing.source == .authenticatedHandshake,
           existing.accountID == normalizedAccountID,
           existing.handshakeIdentity == normalizedHandshakeIdentity,
           existing.bundleIdentifier != normalizedBundleIdentifier {
            // One authenticated transport identity cannot silently switch the
            // app namespace underneath an existing record.
            return false
        }
        let previousRecords = recordsByClientID
        // A modern handshake supersedes every compatibility marker. Once the
        // phone identity is known, no stale picker-derived value may compete
        // with it after this account or variant changes. Keep compatibility
        // records for other accounts so an older client can still route after
        // a second account signs in on the same Mac.
        recordsByClientID = recordsByClientID.filter {
            $0.value.source == .authenticatedHandshake
                || ($0.value.source == .legacyCompatibility
                    && $0.value.accountID != normalizedAccountID)
        }
        recordsByClientID[normalizedClientID] = MobilePairedPhoneRecord(
            clientID: normalizedClientID,
            bundleIdentifier: normalizedBundleIdentifier,
            accountID: normalizedAccountID,
            pairedAt: pairedAt,
            source: .authenticatedHandshake,
            handshakeIdentity: normalizedHandshakeIdentity
        )
        guard trimAndPersist() else {
            recordsByClientID = previousRecords
            return false
        }
        return true
    }

    /// Records a completed authenticated handshake from an iOS build that
    /// predates the bundle-identity status metadata. The legacy target is used
    /// only after this authenticated handshake and is superseded as soon as a
    /// modern client reports its exact bundle.
    @discardableResult
    func recordLegacyCompatibility(
        clientID: String?,
        accountID: String?,
        handshakeIdentity: String?,
        trustedIOSBuildTag: String? = nil,
        pairedAt: Date = .now
    ) -> Bool {
        // A long-lived host singleton can outlive an older settings domain
        // being loaded; retry the one-time import at the authenticated
        // compatibility boundary, never from target lookup itself.
        migrateLegacyPickerSelection()
        guard let normalizedAccountID = Self.normalized(accountID),
              let normalizedHandshakeIdentity = Self.normalized(handshakeIdentity),
              normalizedHandshakeIdentity.utf8.count <= Self.maximumHandshakeIdentityLength,
              let bundleIdentifier = legacyPickerBundleIdentifier
                  ?? legacyCompatibilityBundleIdentifier,
              isBundleAllowedForMacLane(
                  bundleIdentifier,
                  trustedIOSBuildTag: trustedIOSBuildTag
              ) else {
            return false
        }
        guard !recordsByClientID.values.contains(where: {
            $0.source == .authenticatedHandshake
                && $0.accountID == normalizedAccountID
        }) else {
            // A legacy client must never displace an exact modern target that
            // has already completed the bundle-identity handshake.
            return false
        }
        let legacyClientID = Self.legacyCompatibilityClientID(for: clientID)
        let previousRecords = recordsByClientID
        recordsByClientID = recordsByClientID.filter {
            $0.value.source != .legacyPickerMigration
        }
        recordsByClientID[legacyClientID] = MobilePairedPhoneRecord(
            clientID: legacyClientID,
            bundleIdentifier: bundleIdentifier,
            accountID: normalizedAccountID,
            pairedAt: pairedAt,
            source: .legacyCompatibility,
            handshakeIdentity: normalizedHandshakeIdentity
        )
        guard trimAndPersist() else {
            recordsByClientID = previousRecords
            return false
        }
        return true
    }

    /// Resolves the iOS bundle for push and backup requests.
    ///
    /// Only a record created by an authenticated status handshake for the
    /// current account is eligible. Modern records carry the exact bundle;
    /// legacy-compatibility records are limited to pre-metadata clients and are
    /// superseded by the first modern handshake.
    func targetBundleIdentifier(accountID: String?) -> String? {
        guard let normalizedAccountID = Self.normalized(accountID) else {
            return nil
        }
        let candidates = recordsByClientID.values.filter { record in
            (record.source == .authenticatedHandshake
                || record.source == .legacyCompatibility)
                && isBundleAllowedForMacLane(record.bundleIdentifier)
                && record.handshakeIdentity != nil
                && record.accountID == normalizedAccountID
        }
        if let latest = candidates.max(by: Self.recordsSortBefore) {
            return latest.bundleIdentifier
        }
        return nil
    }

    /// Returns the backup namespace for an authenticated account. A precise
    /// handshake target wins; before the first modern handshake, the Mac-lane
    /// fallback keeps legacy paired-Mac restore alive. Push delivery remains
    /// fail-closed until ``targetBundleIdentifier(accountID:)`` is known.
    func backupBundleIdentifier(accountID: String?) -> String? {
        guard Self.normalized(accountID) != nil else { return nil }
        return targetBundleIdentifier(accountID: accountID) ?? fallbackBundleIdentifier
    }

    private var fallbackBundleIdentifier: String? {
        let normalizedTag = macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTag.isEmpty || normalizedTag == "default" {
            return "com.cmux.app"
        }
        return MobileIOSAppNamespace(
            pairedMacInstanceTag: macInstanceTag
        )?.bundleIdentifier
    }

    /// Historical official Macs used the App Store target when talking to an
    /// iOS client that predates bundle metadata. This compatibility value is
    /// reachable only through `recordLegacyCompatibility`, after auth proves a
    /// real handshake; it is never a standalone runtime fallback.
    private var legacyCompatibilityBundleIdentifier: String? {
        let normalizedTag = macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTag.isEmpty || normalizedTag == "default" || normalizedTag == "nightly" {
            return "com.cmux.app"
        }
        return fallbackBundleIdentifier
    }

    private var legacyPickerBundleIdentifier: String? {
        recordsByClientID.values.first {
            $0.source == .legacyPickerMigration
        }?.bundleIdentifier
    }

    private var isOfficialMacLane: Bool {
        let normalizedTag = macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedTag.isEmpty || normalizedTag == "default"
    }

    private func isBundleAllowedForMacLane(
        _ bundleIdentifier: String,
        trustedIOSBuildTag: String? = nil
    ) -> Bool {
        if isOfficialMacLane {
            return Self.officialIOSBundleIdentifiers.contains(bundleIdentifier)
        }
        let normalizedTag = macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTag == "nightly" {
            // Nightly remains a distinct Mac namespace, but its QR is still
            // usable by the four official iOS variants.
            return Self.officialIOSBundleIdentifiers.contains(bundleIdentifier)
                || bundleIdentifier == fallbackBundleIdentifier
        }
        return bundleIdentifier == fallbackBundleIdentifier
            || bundleIdentifier == trustedCrossTagBundleIdentifier(
                trustedIOSBuildTag
            )
    }

    /// An Iroh grant from a tagged phone carries that phone's exact build tag.
    /// Accepting only the corresponding namespace preserves exact-tag pairing
    /// by default while allowing the explicit cross-tag grant flow.
    private func trustedCrossTagBundleIdentifier(_ tag: String?) -> String? {
        let normalizedTag = Self.normalized(tag)?.lowercased()
        guard let normalizedTag,
              !Self.nonDevelopmentTags.contains(normalizedTag),
              let namespace = MobileIOSAppNamespace(
                  pairedMacInstanceTag: normalizedTag
              ),
              namespace.bundleIdentifier.hasPrefix("dev.cmux.ios.") else {
            return nil
        }
        return namespace.bundleIdentifier
    }

    private static let officialIOSBundleIdentifiers: Set<String> = [
        "com.cmux.app",
        "dev.cmux.app.beta",
        "dev.cmux.app.internal",
        "dev.cmux.app.demo",
    ]
    private static let nonDevelopmentTags: Set<String> = [
        "default",
        "nightly",
        "rc",
        "staging",
    ]

    private static func legacyCompatibilityClientID(for clientID: String?) -> String {
        let suffix = normalized(clientID) ?? "default"
        let prefix = "legacy-compatible-"
        let budget = maximumClientIDLength - prefix.utf16.count
        return prefix + String(suffix.prefix(budget))
    }
}

private extension MobilePairedPhoneStore {
    static func decodeRecords(from defaults: UserDefaults) -> [String: MobilePairedPhoneRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let rawRecords = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return [:]
        }
        let decoded = rawRecords.compactMap { rawRecord -> MobilePairedPhoneRecord? in
            guard let object = rawRecord as? [String: Any],
                  let elementData = try? JSONSerialization.data(withJSONObject: object),
                  let record = try? JSONDecoder().decode(
                      MobilePairedPhoneRecord.self,
                      from: elementData
                  ) else {
                return nil
            }
            return record
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
                pairedAt: record.pairedAt,
                source: record.source,
                handshakeIdentity: normalized(record.handshakeIdentity)
            )
        }
    }

    func migrateLegacyPickerSelection() {
        guard let rawLegacyValue = defaults.string(forKey: Self.legacyDefaultsKey) else {
            return
        }
        let previousRecords = recordsByClientID
        if let bundleIdentifier = Self.validBundleIdentifier(rawLegacyValue),
           isBundleAllowedForMacLane(bundleIdentifier) {
            recordsByClientID[Self.legacyClientID] = MobilePairedPhoneRecord(
                clientID: Self.legacyClientID,
                bundleIdentifier: bundleIdentifier,
                accountID: nil,
                pairedAt: .distantPast,
                source: .legacyPickerMigration
            )
            guard trimAndPersist() else {
                recordsByClientID = previousRecords
                return
            }
        }
        // The legacy selection is consumed exactly once. It is retained in the
        // persisted records only as a migration marker; runtime target lookup
        // ignores that source until a new authenticated handshake arrives.
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    @discardableResult
    func trimAndPersist() -> Bool {
        let retained = recordsByClientID.values
            .sorted(by: Self.recordsSortBefore)
            .suffix(Self.maximumRecordCount)
        guard let data = try? JSONEncoder().encode(Array(retained)) else { return false }
        recordsByClientID = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.clientID, $0) }
        )
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
