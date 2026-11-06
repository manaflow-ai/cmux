public import Foundation

/// One minted join line (`cmux machine add --json --no-wait`): the line to paste on the new machine,
/// the non-secret id its joined row will carry, and when it stops working. The token itself is only
/// inside `line`; nothing here keeps it apart.
public nonisolated struct JoinLine: Equatable, Sendable {
    public let line: String
    public let joinTokenId: String
    public let expiresAt: Date
    public let name: String?

    public init(line: String, joinTokenId: String, expiresAt: Date, name: String? = nil) {
        self.line = line
        self.joinTokenId = joinTokenId
        self.expiresAt = expiresAt
        self.name = name
    }

    /// The `--json` object of `cmux machine add`; nil when a field is missing or unreadable.
    /// `expiresAt` is the platform's RFC 3339 UTC time (`Date.toISOString()`, as
    /// `2026-10-29T03:30:00.123Z`); a number is not a time here.
    public static func decode(_ data: Data) -> JoinLine? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = object["line"] as? String, !line.isEmpty,
              let id = object["joinTokenId"] as? String, !id.isEmpty,
              let expires = date(object["expiresAt"]) else { return nil }
        return JoinLine(line: line, joinTokenId: id, expiresAt: expires, name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Why a join line could not be made. The words come from the app, never the CLI's own stderr, so
/// no secret can reach the card.
public nonisolated enum JoinLineFailure: Error, Equatable, Sendable {
    /// The app holds no cmux account to mint with.
    case signedOut
    /// The platform answered 404 or this cmux has no `machine add` mint (the surface is off here).
    case unavailable
    /// Anything else: the CLI failed or timed out.
    case failed
}

/// What the one-line join asks of the app (the bundled CLI and the cmux account), so its flow runs
/// the same in tests with fakes. Every call is one short CLI run; nothing here repeats on its own.
public nonisolated struct MachineJoinService: Sendable {
    /// `cmux machine add [--name NAME] --json --no-wait`: mints a single-use line.
    public var mint: @Sendable (_ name: String?) async -> Result<JoinLine, JoinLineFailure>
    /// `cmux machine list --json`, its joined rows; nil when the run failed.
    public var list: @Sendable () async -> [JoinedMachine]?
    /// `cmux machine doctor ID --json`: the remote end's checks, one HostStep line each.
    public var doctor: @Sendable (_ id: String) async -> [HostStepResult]
    /// A signal for each mesh change the app sees (a machine connects or leaves). The card reads
    /// the list again on each, never on a timer. The stream ends when its consumer is cancelled.
    public var meshChanges: @Sendable () -> AsyncStream<Void>
    /// `cmux machine revoke ID --yes --json`: true when the platform revoked it.
    public var revoke: @Sendable (_ id: String) async -> Bool
    /// `cmux machine rotate ID --json`: true when the platform rotated its credential. The
    /// output is never kept: it may carry the new credential.
    public var rotate: @Sendable (_ id: String) async -> Bool

    public init(mint: @escaping @Sendable (String?) async -> Result<JoinLine, JoinLineFailure>,
                list: @escaping @Sendable () async -> [JoinedMachine]?,
                doctor: @escaping @Sendable (String) async -> [HostStepResult] = MachineJoinService.noSteps,
                meshChanges: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } },
                revoke: @escaping @Sendable (String) async -> Bool = MachineJoinService.refuse,
                rotate: @escaping @Sendable (String) async -> Bool = MachineJoinService.refuse) {
        self.mint = mint
        self.list = list
        self.doctor = doctor
        self.meshChanges = meshChanges
        self.revoke = revoke
        self.rotate = rotate
    }

    /// No checks: ``doctor``'s default, a named function rather than an async closure literal as a
    /// default argument (crash ratchet, cx-bsue).
    @Sendable public static func noSteps(_ id: String) async -> [HostStepResult] { [] }

    /// Changes nothing: ``revoke`` and ``rotate``'s default (a named function, not an async closure
    /// literal as a default argument; crash ratchet, cx-bsue).
    @Sendable public static func refuse(_ id: String) async -> Bool { false }

    /// The HostStep lines of a doctor run's stdout (the final `{"report":…}` line and anything else
    /// that is not a step are skipped).
    public static func steps(_ stdout: String) -> [HostStepResult] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            try? JSONDecoder().decode(HostStepResult.self, from: Data(line.utf8))
        }
    }
}
