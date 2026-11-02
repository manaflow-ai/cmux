import CCmuxLayoutReducerFFI
public import Foundation

/// What a `cloud.startChat` start does about its machine's harness login, and why (the App's
/// `CloudStartChat+Login`). A start that passes no login leaves Claude there signed out or on a
/// rejected login, and every turn then fails with the bare "The provider rejected Claude Code's
/// credentials on this Cloud machine" card. So the start logs this decision and keeps it on the machine's
/// `cloud.machines` row (`harness_login`), never a silent skip.
///
/// The rules are Rust's (cmux-tui/crates/cmux-cloud-start-core `harness_login`, with their tests),
/// asked over the app FFI (`cloud_harness_login*`); this type holds what the start knows so far and
/// reads the decision back.
public nonisolated struct CloudHarnessLoginDecision: Sendable, Equatable {
    public enum Step: String, Sendable, Equatable, Decodable { case skip, install, confirmThenInstall = "confirm-then-install" }

    /// The rules' reasons (cmux-cloud-start-core `Reason`), plus ``ffiFailed`` when the FFI did not answer.
    public enum Reason: String, Sendable, Equatable, Decodable {
        case buildGateOff = "build-gate-off"
        case noTransfer = "no-transfer-for-harness"
        case signedOut = "signed-out"
        case callerNotOwner = "caller-not-owner"
        case guestNotOwner = "guest-not-owner"
        case guestUnread = "guest-kind-unread"
        case machineLoginKept = "machine-login-kept"
        case installCached = "install-cached"
        case confirmFirst = "confirm-first"
        /// The app FFI gave no answer: the start passes no login (never a silent one: the record says so).
        case ffiFailed = "ffi-failed"
    }

    public var gate: Bool
    public var provider: CloudCredentialTransfer.Provider?
    public var signedIn: Bool
    /// Nil when not asked (an earlier check decided).
    public var callerOwns: Bool?
    /// The guest's `/etc/cmux/vm-kind` ("" when missing); nil when not read or the read failed.
    public var guestKind: String?
    public var machineLogin: CloudMachineLogin?
    public var cached: Bool
    /// What came of it once decided: "installed", "declined" (the confirm), or the transfer's fixed failure text.
    public var outcome: String?

    public init(gate: Bool, provider: CloudCredentialTransfer.Provider?, signedIn: Bool, callerOwns: Bool? = nil,
                guestKind: String? = nil, machineLogin: CloudMachineLogin? = nil, cached: Bool = false) {
        (self.gate, self.provider, self.signedIn, self.callerOwns) = (gate, provider, signedIn, callerOwns)
        (self.guestKind, self.machineLogin, self.cached) = (guestKind, machineLogin, cached)
    }

    /// The rules' answer for these inputs.
    public struct Verdict: Sendable, Equatable, Decodable {
        public var step: Step
        public var reason: Reason
        public var readsMachine: Bool
        public var guestTakesLogin: Bool
        public var skippedTeamMachine: Bool
        public var summary: String
    }

    private struct Request: Encodable {
        var gate: Bool, provider: String?, signedIn: Bool, callerOwns: Bool?, guestKind: String?
        var machineLogin: String?, cached: Bool, outcome: String?
    }

    /// Asks the rules once; read every field off the one answer.
    public var verdict: Verdict {
        let request = Request(gate: gate, provider: provider?.rawValue, signedIn: signedIn, callerOwns: callerOwns, guestKind: guestKind,
                              machineLogin: machineLogin?.rawValue, cached: cached, outcome: outcome)
        return Self.call("cloud_harness_login", request, as: Verdict.self) ?? Verdict(
            step: .skip, reason: .ffiFailed, readsMachine: false, guestTakesLogin: false, skippedTeamMachine: false,
            summary: "skip (ffi-failed)" + (outcome.map { " -> \($0)" } ?? ""))
    }

    public var step: Step { verdict.step }
    public var reason: Reason { verdict.reason }
    /// The start passed no personal login because the machine is a team machine (handshake `cloudTeamMachine`).
    public var skippedTeamMachine: Bool { verdict.skippedTeamMachine }
    /// Whether the guest takes the caller's login (an `owner` or `team` guest of the caller's own machine).
    public var guestTakesLogin: Bool { verdict.guestTakesLogin }
    /// Whether the start reads the guest and its login: only once the earlier checks let it go on.
    public var readsMachine: Bool { verdict.readsMachine }
    /// One line for the log and the `cloud.machines` row; no token, path or provider output.
    public var summary: String { verdict.summary }

    /// The provider whose login a start needs; nil for a harness that has no transfer (pi, opencode).
    /// No harness named is the app's default agent, Claude.
    public static func loginProvider(harness: String?) -> CloudCredentialTransfer.Provider? {
        struct Request: Encodable { var harness: String? }
        struct Reply: Decodable { var provider: String? }
        return call("cloud_harness_login_provider", Request(harness: harness), as: Reply.self)?.provider
            .flatMap(CloudCredentialTransfer.Provider.init(rawValue:))
    }

    /// Prints the guest's kind after a fixed marker, so an exec that ran is told from one that failed.
    public static let guestKindProbe: String = {
        struct Reply: Decodable { var probe: String }
        // An empty probe prints nothing, which reads as an unread kind (`guest-kind-unread`).
        return call("cloud_guest_kind_probe", [String: String](), as: Reply.self)?.probe ?? ""
    }()

    /// The kind ``guestKindProbe`` printed ("" when the guest has none), or nil for output without the marker.
    public static func guestKind(stdout: String) -> String? {
        struct Request: Encodable { var stdout: String }
        struct Reply: Decodable { var kind: String? }
        return call("cloud_guest_kind", Request(stdout: stdout), as: Reply.self)?.kind
    }

    /// One JSON call of the app FFI; nil when it does not answer.
    private static func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(outputLength)))
        }
        return nil
    }
}
