public import Foundation

/// A Computer Use worker's question, unchanged from the asking machine
/// (docs/device-hub/PROTOCOL.md, "Computer Use approvals"; docs/computer-use-approvals.md).
/// Every field is kept as sent, so the digest is recomputed over all of them,
/// including fields this build does not know.
public struct ComputerUseApprovalRequest: Sendable, Equatable, Codable {
    /// The app the agent wants to use, as the worker resolved it (never the agent's words).
    public struct Target: Sendable, Equatable {
        public var bundleID: String?
        public var executable: String?
        public var name: String

        public init(bundleID: String?, executable: String?, name: String) {
            self.bundleID = bundleID; self.executable = executable; self.name = name
        }
    }

    /// The request object as sent, `digest` included.
    public var fields: [String: HubJSON]

    public init(fields: [String: HubJSON]) {
        self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        fields = try container.decode([String: HubJSON].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }

    public var version: Int64? { fields["v"]?.integerValue }
    public var nonce: String? { fields["nonce"]?.stringValue }
    /// The cmux client that asks (`com.cmuxterm.app`, a DEV tag's bundle id, cmux-tui).
    public var client: String? { fields["client"]?.stringValue }
    public var machine: String? { fields["machine"]?.stringValue }
    public var session: String? { fields["session"]?.stringValue }
    /// Display labels set by the asking machine, never authority.
    public var agent: String? { fields["agent"]?.stringValue }
    public var workspace: String? { fields["workspace"]?.stringValue }
    public var tool: String? { fields["tool"]?.stringValue }
    public var risk: String? { fields["risk"]?.stringValue }
    public var digest: String? { fields["digest"]?.stringValue }

    public var target: Target? {
        guard let object = fields["target"]?.objectValue, let name = object["name"]?.stringValue else { return nil }
        return Target(bundleID: object["bundle_id"]?.stringValue, executable: object["executable"]?.stringValue, name: name)
    }

    public var createdAt: Date? { date("created_ms") }
    /// Until when the agent's call waits for an answer.
    public var waitUntil: Date? { date("wait_until_ms") }
    /// Until when an answer still counts (a late Allow covers the agent's retry).
    public var answerableUntil: Date? { date("answerable_until_ms") }

    private func date(_ key: String) -> Date? {
        fields[key]?.integerValue.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// The lowercase hex SHA-256 of the canonical JSON of the request without `digest`.
    public func computedDigest() throws -> String {
        var unsigned = fields
        unsigned["digest"] = nil
        return try HubJSON.object(unsigned).canonicalSHA256()
    }

    /// Whether `digest` is the digest of the request's other fields.
    public var digestMatches: Bool {
        guard let digest, let computed = try? computedDigest() else { return false }
        return digest == computed
    }
}

/// An answer to a Computer Use question.
public enum ComputerUseDecision: String, Codable, Sendable, Equatable, CaseIterable {
    /// Runs this call only.
    case once
    /// Adds the app to this agent session.
    case session
    /// Adds the app to the asking client's saved list (only when the request allows it).
    case always
    /// Refuses this call.
    case deny

    /// The UTF-8 string the deciding device signs: `"cmux-cu-approval-v1\n<digest>\n<decision>"`.
    public func signatureMessage(digest: String) -> String {
        "cmux-cu-approval-v1\n\(digest)\n\(rawValue)"
    }
}

public enum ComputerUseApprovalState: String, Codable, Sendable, Equatable {
    case pending, decided, expired, cancelled
}

/// One approval the hub stores (`GET /v1/approvals/:id`, `approval.request`).
public struct ComputerUseApproval: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// The asking machine.
    public var deviceId: String
    /// The asking machine's hub name.
    public var deviceName: String
    public var request: ComputerUseApprovalRequest
    /// The asking machine's `computerUse.phoneAlwaysAllow`: Always Allow may be offered.
    public var allowAlways: Bool
    /// Nil for a state this build does not know (never answerable). An `approval.request` push has none: pending.
    public var state: ComputerUseApprovalState?
    public var decision: ComputerUseDecision?
    public var deciderId: String?
    public var sig: String?
    public var createdAt: Date?
    public var answerableUntil: Date?
    public var decidedAt: Date?

    public init(id: String, deviceId: String, deviceName: String, request: ComputerUseApprovalRequest, allowAlways: Bool = false,
                state: ComputerUseApprovalState? = .pending, decision: ComputerUseDecision? = nil, deciderId: String? = nil,
                sig: String? = nil, createdAt: Date? = nil, answerableUntil: Date? = nil, decidedAt: Date? = nil) {
        self.id = id; self.deviceId = deviceId; self.deviceName = deviceName; self.request = request
        self.allowAlways = allowAlways; self.state = state; self.decision = decision; self.deciderId = deciderId
        self.sig = sig; self.createdAt = createdAt; self.answerableUntil = answerableUntil; self.decidedAt = decidedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, deviceId, deviceName, request, allowAlways, state, decision, deciderId, sig, createdAt, answerableUntil, decidedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        request = try c.decode(ComputerUseApprovalRequest.self, forKey: .request)
        deviceName = c.lenient(String.self, .deviceName) ?? ""
        allowAlways = c.flag(.allowAlways)
        if let raw = c.lenient(String.self, .state) {
            state = ComputerUseApprovalState(rawValue: raw)
        } else {
            state = .pending
        }
        decision = c.lenient(ComputerUseDecision.self, .decision)
        deciderId = c.lenient(String.self, .deciderId)
        sig = c.lenient(String.self, .sig)
        createdAt = c.date(.createdAt)
        answerableUntil = c.date(.answerableUntil)
        decidedAt = c.date(.decidedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(request, forKey: .request)
        try c.encode(allowAlways, forKey: .allowAlways)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(decision, forKey: .decision)
        try c.encodeIfPresent(deciderId, forKey: .deciderId)
        try c.encodeIfPresent(sig, forKey: .sig)
        try c.encodeIfPresent(createdAt.map { ($0.timeIntervalSince1970 * 1000).rounded() }, forKey: .createdAt)
        try c.encodeIfPresent(answerableUntil.map { ($0.timeIntervalSince1970 * 1000).rounded() }, forKey: .answerableUntil)
        try c.encodeIfPresent(decidedAt.map { ($0.timeIntervalSince1970 * 1000).rounded() }, forKey: .decidedAt)
    }

    /// Why this device must not show or answer this approval.
    public enum Refusal: Error, Sendable, Equatable {
        /// This device asked it: no device answers its own question.
        case ownRequest
        /// The request's digest is missing or is not the digest of its fields.
        case digestMismatch
        /// Already decided, expired or cancelled (or a state this build does not know).
        case notPending
        /// Past the request's `answerable_until_ms`.
        case expired
    }

    /// The deadline that counts: the request's own (inside the digest), else the hub's.
    public var deadline: Date? { request.answerableUntil ?? answerableUntil }

    /// Nil when `thisDeviceID` may answer it at `now`, else why not. Checked in this order:
    /// the asker, the digest, the state, the deadline.
    public func refusal(thisDeviceID: String, now: Date) -> Refusal? {
        if deviceId.lowercased() == thisDeviceID.lowercased() { return .ownRequest }
        guard request.digestMatches else { return .digestMismatch }
        guard state == .pending else { return .notPending }
        guard let deadline, now < deadline else { return .expired }
        return nil
    }
}

/// `approval.decided`, to the asking device.
public struct ComputerUseApprovalDecided: Codable, Sendable, Equatable {
    public var id: String
    public var decision: ComputerUseDecision
    public var digest: String
    public var deciderId: String
    public var sig: String

    public init(id: String, decision: ComputerUseDecision, digest: String, deciderId: String, sig: String) {
        self.id = id; self.decision = decision; self.digest = digest; self.deciderId = deciderId; self.sig = sig
    }

    /// Whether `sig` is `signingKey`'s signature of this decision over `digest`.
    public func verifies(signingKey: String) -> Bool {
        DeviceIdentity.verifyApproval(signature: sig, digest: digest, decision: decision, signingKey: signingKey)
    }
}

extension DeviceIdentity {
    /// base64 raw r||s ECDSA-P256-SHA256 over `"cmux-cu-approval-v1\n<digest>\n<decision>"`.
    public func signApproval(digest: String, decision: ComputerUseDecision) throws -> String {
        try sign(canonical: decision.signatureMessage(digest: digest))
    }

    /// Whether `signature` (base64 raw r||s, high-S accepted) is `signingKey`'s decision signature.
    public static func verifyApproval(signature: String, digest: String, decision: ComputerUseDecision, signingKey: String) -> Bool {
        verify(signature: signature, of: Data(decision.signatureMessage(digest: digest).utf8), signingKey: signingKey)
    }
}

/// `PUT /v1/devices/:id/push`'s environment: which APNs gateway the token belongs to.
public enum DeviceHubPushEnvironment: String, Codable, Sendable, Equatable {
    case production, development
}

/// `PUT /v1/devices/:id/push`'s answer.
public struct DeviceHubPushRegistration: Codable, Sendable, Equatable {
    /// The hub holds a token for this device.
    public var registered: Bool
    /// The hub can send APNs at all; without it questions reach the phone only over its socket.
    public var configured: Bool

    public init(registered: Bool, configured: Bool) {
        self.registered = registered; self.configured = configured
    }

    enum CodingKeys: String, CodingKey { case registered, configured }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        registered = c.flag(.registered)
        configured = c.flag(.configured)
    }
}
