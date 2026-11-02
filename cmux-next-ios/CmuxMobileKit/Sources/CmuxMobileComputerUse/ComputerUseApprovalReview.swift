public import CmuxDeviceHub
public import CmuxMobileNotifications
public import Foundation

/// One answer the phone offers to a Computer Use question.
public enum ComputerUseChoice: String, Hashable, Sendable, CaseIterable {
    case allowOnce
    case allowSession
    /// "Always Allow <App>": only when the asking machine allows it, behind Face ID.
    case alwaysAllow
    case deny

    public var decision: ComputerUseDecision {
        switch self {
        case .allowOnce: .once
        case .allowSession: .session
        case .alwaysAllow: .always
        case .deny: .deny
        }
    }

    /// Every Allow is signed only after Face ID (or the passcode); Deny never grants anything.
    public var needsUserPresence: Bool { self != .deny }

    /// The notification button's choice.
    public init(_ action: ComputerUseApprovalAction) {
        switch action {
        case .allowOnce: self = .allowOnce
        case .allowSession: self = .allowSession
        case .allowAlways: self = .alwaysAllow
        case .deny: self = .deny
        }
    }
}

/// A Computer Use question the phone checked: what the sheet shows and which
/// answers it offers. One model for both ways a question arrives:
/// - the device hub (Windows, Linux, VMs, and Macs through the hub): built from the
///   approval fetched from the hub, never from a push's text;
/// - a Mac's cmux app through its iPhone host: built from the request the Mac sent
///   inside its push (sealed when the Mac seals).
/// Building it recomputes the digest from the request and refuses a mismatch, a
/// question past its deadline, and (hub) one this phone asked or no longer pending.
public struct ComputerUseApprovalReview: Identifiable, Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// `approvalID` on the device hub.
        case hub(approvalID: String)
        /// A Mac's app: answered over that Mac's link or the reply mailbox.
        case mac(id: String, name: String?)
    }

    public let source: Source
    public let request: ComputerUseApprovalRequest
    /// The digest this phone recomputed from the request (the one it signs).
    public let digest: String
    /// The asking machine allows Always Allow from a phone.
    public let allowAlways: Bool
    let hubDeviceName: String?

    public var id: String {
        switch source {
        case let .hub(approvalID): approvalID
        case let .mac(mac, _): "mac:\(mac):\(digest)"
        }
    }

    /// A question from the device hub, as fetched from it.
    public init(approval: ComputerUseApproval, thisDeviceID: String, now: Date) throws(ComputerUseApproval.Refusal) {
        if let refusal = approval.refusal(thisDeviceID: thisDeviceID, now: now) { throw refusal }
        guard let digest = try? approval.request.computedDigest() else { throw .digestMismatch }
        source = .hub(approvalID: approval.id)
        request = approval.request
        self.digest = digest
        allowAlways = approval.allowAlways
        hubDeviceName = approval.deviceName
    }

    /// A question from `macID`'s app, as its push carried it.
    public init(macRequest: ComputerUseApprovalRequest, always: Bool, macID: String, macName: String?, now: Date)
        throws(ComputerUseApproval.Refusal) {
        guard macRequest.digestMatches, let digest = macRequest.digest else { throw .digestMismatch }
        guard let deadline = macRequest.answerableUntil, now < deadline else { throw .expired }
        source = .mac(id: macID, name: macName)
        request = macRequest
        self.digest = digest
        allowAlways = always
        hubDeviceName = nil
    }

    /// A Mac push's question (kind `computer_use`); a push without one refuses as a mismatch.
    public init(payload: PushPayload, now: Date) throws(ComputerUseApproval.Refusal) {
        guard payload.kind == .computerUse, let mac = payload.mac, let question = payload.computerUse,
              let request = ComputerUseApprovalRequest(question.request) else { throw .digestMismatch }
        try self.init(macRequest: request, always: question.always, macID: mac, macName: payload.macName, now: now)
    }

    /// The asking machine: its hub name, or the Mac's name.
    public var machineName: String {
        let named: String? = switch source {
        case .hub: hubDeviceName
        case let .mac(_, name): name
        }
        let name = named?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (request.machine ?? String(localized: "A device")) : name
    }

    public var agent: String { request.agent ?? String(localized: "An agent") }
    public var workspace: String? { request.workspace }
    public var tool: String? { request.tool }
    public var appName: String { request.target?.name ?? String(localized: "an app") }
    /// The app's bundle id or executable path, to tell two apps of one name apart.
    public var appIdentifier: String? { request.target.flatMap { $0.bundleID ?? $0.executable } }
    public var deadline: Date? { request.answerableUntil }

    /// The answers offered, in order: Always Allow only when the asking machine allows it.
    public var choices: [ComputerUseChoice] {
        allowAlways ? [.allowOnce, .allowSession, .alwaysAllow, .deny] : [.allowOnce, .allowSession, .deny]
    }

    public func offers(_ choice: ComputerUseChoice) -> Bool { choices.contains(choice) }

    /// The line the Face ID sheet shows for `choice`.
    public func userPresenceReason(for choice: ComputerUseChoice) -> String {
        switch choice {
        case .allowOnce: String(localized: "Allow \(agent) to use \(appName) once on \(machineName)")
        case .allowSession: String(localized: "Allow \(agent) to use \(appName) for this session on \(machineName)")
        case .alwaysAllow: String(localized: "Always allow \(appName) on \(machineName)")
        case .deny: String(localized: "Deny \(agent) the use of \(appName)")
        }
    }
}

extension ComputerUseApprovalRequest {
    /// The request of a Mac's push, every field as sent.
    public init?(_ json: PushJSON) {
        guard case let .object(object) = json else { return nil }
        self.init(fields: object.mapValues { HubJSON($0) })
    }
}

extension HubJSON {
    init(_ json: PushJSON) {
        switch json {
        case .null: self = .null
        case let .bool(value): self = .bool(value)
        case let .int(value): self = .integer(value)
        case let .string(value): self = .string(value)
        case let .array(values): self = .array(values.map { HubJSON($0) })
        case let .object(object): self = .object(object.mapValues { HubJSON($0) })
        }
    }
}

extension ComputerUseApproval.Refusal {
    /// What the phone says when it will not answer.
    public var message: String {
        switch self {
        case .ownRequest: String(localized: "This request came from this iPhone, so it can't answer it.")
        case .digestMismatch: String(localized: "This request didn't check out, so cmux won't answer it.")
        case .notPending: String(localized: "This request was already answered or cancelled.")
        case .expired: String(localized: "This request has expired.")
        }
    }
}
