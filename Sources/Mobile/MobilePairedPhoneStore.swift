import CMUXMobileCore
import Foundation

/// How a paired-phone record became known to the Mac.
enum MobilePairedPhoneRecordSource: String, Codable, Sendable {
    case authenticatedHandshake
    case legacyPickerMigration
}

/// The iOS application identity learned from one completed Mac pairing.
struct MobilePairedPhoneRecord: Codable, Equatable, Sendable {
    let clientID: String
    let bundleIdentifier: String
    let accountID: String?
    let pairedAt: Date
    let source: MobilePairedPhoneRecordSource
    /// A stable proof boundary for the authenticated transport that observed
    /// this install. It is intentionally not a bearer token.
    let handshakeIdentity: String?

    init(
        clientID: String,
        bundleIdentifier: String,
        accountID: String?,
        pairedAt: Date,
        source: MobilePairedPhoneRecordSource = .authenticatedHandshake,
        handshakeIdentity: String? = nil
    ) {
        self.clientID = clientID
        self.bundleIdentifier = bundleIdentifier
        self.accountID = accountID
        self.pairedAt = pairedAt
        self.source = source
        self.handshakeIdentity = handshakeIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case clientID
        case bundleIdentifier
        case accountID
        case pairedAt
        case source
        case handshakeIdentity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientID: try container.decode(String.self, forKey: .clientID),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            accountID: try container.decodeIfPresent(String.self, forKey: .accountID),
            pairedAt: try container.decode(Date.self, forKey: .pairedAt),
            source: try container.decodeIfPresent(
                MobilePairedPhoneRecordSource.self,
                forKey: .source
            ) ?? .authenticatedHandshake,
            handshakeIdentity: try container.decodeIfPresent(
                String.self,
                forKey: .handshakeIdentity
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(accountID, forKey: .accountID)
        try container.encode(pairedAt, forKey: .pairedAt)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(handshakeIdentity, forKey: .handshakeIdentity)
    }
}

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
        pairedAt: Date = .now
    ) -> Bool {
        guard let normalizedClientID = Self.normalized(clientID),
              normalizedClientID.utf16.count <= Self.maximumClientIDLength,
              normalizedClientID != Self.legacyClientID,
              let normalizedBundleIdentifier = Self.validBundleIdentifier(bundleIdentifier),
              isBundleAllowedForMacLane(normalizedBundleIdentifier)
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
           existing.bundleIdentifier != normalizedBundleIdentifier {
            // One authenticated transport identity cannot silently switch the
            // app namespace underneath an existing record.
            return false
        }
        let previousRecords = recordsByClientID
        // A real handshake supersedes the pre-migration picker fallback. Once
        // the phone identity is known, the stale global value must not compete
        // with it after account or variant changes.
        recordsByClientID.removeValue(forKey: Self.legacyClientID)
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

    /// Resolves the iOS bundle for push and backup requests.
    ///
    /// Only an authenticated record for the current account is eligible. If no
    /// phone has completed the post-handshake identity exchange, return `nil` so
    /// push and backup callers fail closed instead of guessing from a picker
    /// default or the Mac's build lane.
    func targetBundleIdentifier(accountID: String?) -> String? {
        guard let normalizedAccountID = Self.normalized(accountID) else {
            return nil
        }
        let candidates = recordsByClientID.values.filter { record in
            record.source == .authenticatedHandshake
                && isBundleAllowedForMacLane(record.bundleIdentifier)
                && record.handshakeIdentity != nil
                && record.accountID == normalizedAccountID
        }
        if let latest = candidates.max(by: Self.recordsSortBefore) {
            return latest.bundleIdentifier
        }
        return nil
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

    private var isOfficialMacLane: Bool {
        let normalizedTag = macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedTag.isEmpty || normalizedTag == "default"
    }

    private func isBundleAllowedForMacLane(_ bundleIdentifier: String) -> Bool {
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
    }

    private static let officialIOSBundleIdentifiers: Set<String> = [
        "com.cmux.app",
        "dev.cmux.app.beta",
        "dev.cmux.app.internal",
        "dev.cmux.app.demo",
    ]
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
