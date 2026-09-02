import CryptoKit
import Foundation

/// An in-memory, fail-closed bearer-grant repository for the Mac browser bridge.
///
/// Grants are deliberately process-lifetime credentials for this first slice:
/// stopping or relaunching cmux invalidates every browser token. The store keeps
/// only SHA-256 digests, so a grant listing can never disclose a usable token.
/// The actor is the sole owner of mutable grant state; callers receive value
/// snapshots and the one-time token returned when a grant is issued.
actor WebClientGrantStore {
    enum IssueError: Error, Equatable, Sendable {
        case limitReached
    }

    struct IssuedGrant: Sendable {
        let snapshot: WebClientGrantSnapshot
        let token: String
    }

    private struct Record: Sendable {
        let id: UUID
        let label: String
        let tokenDigest: Data
        let createdAt: Date
        var lastUsedAt: Date?
        var revokedAt: Date?
    }

    private let now: @Sendable () -> Date
    private let tokenDataGenerator: @Sendable () -> Data
    private let maximumRecordCount = 256
    private var records: [UUID: Record] = [:]

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        tokenDataGenerator: @escaping @Sendable () -> Data = {
            WebClientGrantStore.randomTokenData()
        }
    ) {
        self.now = now
        self.tokenDataGenerator = tokenDataGenerator
    }

    /// Issues one independent bearer token. The token is returned only from
    /// this call and is never included in a snapshot or log message.
    func issue(label: String?) throws -> IssuedGrant {
        if records.count >= maximumRecordCount {
            let revoked = records.values
                .filter { $0.revokedAt != nil }
                .sorted { $0.createdAt < $1.createdAt }
            for record in revoked where records.count >= maximumRecordCount {
                records.removeValue(forKey: record.id)
            }
        }
        guard records.count < maximumRecordCount else {
            throw IssueError.limitReached
        }
        let id = UUID()
        let createdAt = now()
        let normalizedLabel = Self.normalizedLabel(label)
        let token = Self.encodeToken(tokenDataGenerator())
        records[id] = Record(
            id: id,
            label: normalizedLabel,
            tokenDigest: Self.digest(token),
            createdAt: createdAt,
            lastUsedAt: nil,
            revokedAt: nil
        )
        return IssuedGrant(
            snapshot: WebClientGrantSnapshot(
                id: id,
                label: normalizedLabel,
                createdAt: createdAt,
                lastUsedAt: nil,
                revokedAt: nil
            ),
            token: token
        )
    }

    /// Authenticates a bearer token and records its last-use time.
    func authenticate(token: String) -> UUID? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let digest = Self.digest(normalized)
        guard let id = records.first(where: { record in
            record.value.revokedAt == nil && Self.constantTimeEqual(record.value.tokenDigest, digest)
        })?.key else {
            return nil
        }
        records[id]?.lastUsedAt = now()
        return id
    }

    /// Returns whether a grant is still usable for an already-open connection.
    func isActive(_ id: UUID) -> Bool {
        guard let record = records[id] else { return false }
        return record.revokedAt == nil
    }

    /// Revokes one grant. Repeated revocation is idempotent and reports false
    /// when the id is unknown or was already revoked.
    @discardableResult
    func revoke(_ id: UUID) -> Bool {
        guard var record = records[id], record.revokedAt == nil else { return false }
        record.revokedAt = now()
        records[id] = record
        return true
    }

    /// Revokes every active grant and returns the ids that changed state.
    func revokeAll() -> [UUID] {
        let active = records.values.filter { $0.revokedAt == nil }.map(\.id)
        let timestamp = now()
        for id in active {
            records[id]?.revokedAt = timestamp
        }
        return active
    }

    /// Returns redacted grant metadata in stable creation order.
    func snapshots() -> [WebClientGrantSnapshot] {
        records.values
            .map { record in
                WebClientGrantSnapshot(
                    id: record.id,
                    label: record.label,
                    createdAt: record.createdAt,
                    lastUsedAt: record.lastUsedAt,
                    revokedAt: record.revokedAt
                )
            }
            .sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.createdAt < right.createdAt
            }
    }

    private static func normalizedLabel(_ label: String?) -> String {
        let value = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultLabel = String(
            localized: "webClientBridge.defaultGrantLabel",
            defaultValue: "Browser client"
        )
        guard !value.isEmpty else { return defaultLabel }
        let sanitizedScalars = value.unicodeScalars.lazy.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.prefix(80)
        let sanitized = String(String.UnicodeScalarView(sanitizedScalars))
        guard !sanitized.isEmpty else { return defaultLabel }
        return sanitized
    }

    private static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func encodeToken(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        return "cmux_web_" + encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomTokenData() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
        })
    }
}
