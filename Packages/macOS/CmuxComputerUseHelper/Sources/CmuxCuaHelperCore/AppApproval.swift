// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app a Computer Use call targets, as the worker resolved it (never the
/// agent's words). On macOS it is a bundle id; Windows and Linux hosts name
/// an executable path. Exactly one of the two is set.
public struct ApprovalApp: Sendable, Hashable {
    public let bundleID: String?
    public let executable: String?
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.executable = nil
        self.name = name
    }

    public init(executable: String, name: String) {
        self.bundleID = nil
        self.executable = executable
        self.name = name
    }

    /// An app from the host (`approved_apps`, `revoke`): exactly one
    /// non-empty `bundle_id` or `executable` string, and an optional `name`.
    public init?(wire: [String: Any]) {
        let bundle = (wire["bundle_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let executable = (wire["executable"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = wire["name"] as? String
        switch (bundle, executable) {
        case let (bundle?, nil): self.init(bundleID: bundle, name: name ?? bundle)
        case let (nil, executable?): self.init(executable: executable, name: name ?? executable)
        default: return nil
        }
    }

    /// Identity for grants and questions: bundle ids compare without case
    /// (as `CuaTargetPolicy` does); the display name never counts.
    public var key: String {
        if let bundleID { return "bundle:" + bundleID.lowercased() }
        return "executable:" + (executable ?? "")
    }

    /// `{"bundle_id","executable","name"}`, both identity keys present.
    var wire: [String: Any] {
        ["bundle_id": bundleID ?? NSNull(), "executable": executable ?? NSNull(), "name": name]
    }

    public static func == (lhs: ApprovalApp, rhs: ApprovalApp) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// A person's answer to an app approval question.
public enum AppApprovalDecision: String, Sendable, CaseIterable {
    /// This call only.
    case once
    /// This agent session: the app joins the session's manifest.
    case session
    /// This cmux client's saved list, and this session.
    case always
    /// Refuse this call.
    case deny
}

/// Display labels for one agent session, from `session/hello`. They are
/// shown on the approval card and are never authority.
public struct SessionLabels: Sendable, Equatable {
    public var agent: String
    public var workspace: String
    public var client: String

    public init(agent: String = "", workspace: String = "", client: String = "") {
        self.agent = agent
        self.workspace = workspace
        self.client = client
    }

    /// `session/hello` params: strings only, each cut to 200 characters;
    /// anything else is empty.
    init(hello params: [String: Any]) {
        func label(_ key: String) -> String { String((params[key] as? String ?? "").prefix(200)) }
        self.init(agent: label("agent"), workspace: label("workspace"), client: label("client"))
    }
}

/// One approval question (docs/computer-use-approvals.md, "The approval
/// question"). Its digest is the SHA-256 of the canonical JSON of every
/// field below; a decision counts only with the same digest.
public struct AppApprovalRequest: Sendable {
    public static let version = 1

    public let nonce: String
    public let client: String
    public let machine: String
    public let session: String
    public let agent: String
    public let workspace: String
    public let target: ApprovalApp
    public let tool: String
    public let risk: String
    public let createdMs: Int64
    public let waitUntilMs: Int64
    public let answerableUntilMs: Int64
    public let digest: String

    public init(nonce: String, client: String, machine: String, session: String, agent: String, workspace: String,
                target: ApprovalApp, tool: String, risk: String,
                createdMs: Int64, waitUntilMs: Int64, answerableUntilMs: Int64) {
        self.nonce = nonce
        self.client = client
        self.machine = machine
        self.session = session
        self.agent = agent
        self.workspace = workspace
        self.target = target
        self.tool = tool
        self.risk = risk
        self.createdMs = createdMs
        self.waitUntilMs = waitUntilMs
        self.answerableUntilMs = answerableUntilMs
        digest = CanonicalJSON.sha256Hex(Self.canonical(Self.fields(nonce: nonce, client: client, machine: machine,
                                                                    session: session, agent: agent,
                                                                    workspace: workspace, target: target, tool: tool,
                                                                    risk: risk, createdMs: createdMs,
                                                                    waitUntilMs: waitUntilMs,
                                                                    answerableUntilMs: answerableUntilMs)))
    }

    /// The request object without its digest: what the digest covers.
    var unsigned: [String: Any] {
        Self.fields(nonce: nonce, client: client, machine: machine, session: session, agent: agent,
                    workspace: workspace, target: target, tool: tool, risk: risk, createdMs: createdMs,
                    waitUntilMs: waitUntilMs, answerableUntilMs: answerableUntilMs)
    }

    /// The canonical bytes the digest covers.
    var canonical: Data { Self.canonical(unsigned) }

    /// The request object on the wire, with its digest.
    var wire: [String: Any] { unsigned.merging(["digest": digest]) { _, new in new } }

    private static func fields(nonce: String, client: String, machine: String, session: String, agent: String,
                               workspace: String, target: ApprovalApp, tool: String, risk: String,
                               createdMs: Int64, waitUntilMs: Int64, answerableUntilMs: Int64) -> [String: Any] {
        [
            "v": version, "nonce": nonce, "client": client, "machine": machine, "session": session,
            "agent": agent, "workspace": workspace, "target": target.wire, "tool": tool, "risk": risk,
            "created_ms": NSNumber(value: createdMs), "wait_until_ms": NSNumber(value: waitUntilMs),
            "answerable_until_ms": NSNumber(value: answerableUntilMs),
        ]
    }

    /// Every field is a string, an integer or a string map, which the
    /// canonical encoder always accepts.
    private static func canonical(_ fields: [String: Any]) -> Data {
        (try? CanonicalJSON.encode(fields)) ?? Data()
    }
}

/// A call refused for an app approval, in place of running.
public struct AppApprovalRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable {
        /// Nobody answered within the wait (2 minutes). The question stays
        /// answerable, so a later Allow covers the agent's retry.
        case timeout = "approval_timeout"
        /// The person chose Deny.
        case denied = "approval_denied"
        /// No collector could ask: no host link, the host answered
        /// `ok:false`, the link closed, or the session ended.
        case unavailable = "approval_unavailable"
    }

    public let code: Code
    public let app: String
    public let tool: String

    public init(code: Code, app: String, tool: String) {
        self.code = code
        self.app = app
        self.tool = tool
    }

    public var description: String {
        switch code {
        case .timeout:
            "\(code.rawValue): nobody answered the request to use \(app) in time. `\(tool)` did not run. "
                + "The request stays open for a few minutes; if the person allows it, try again."
        case .denied:
            "\(code.rawValue): the person denied using \(app). `\(tool)` did not run."
        case .unavailable:
            "\(code.rawValue): Computer Use could not ask the person to allow \(app). `\(tool)` did not run."
        }
    }
}
