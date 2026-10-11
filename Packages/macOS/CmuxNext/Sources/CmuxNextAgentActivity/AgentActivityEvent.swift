public import Foundation

public nonisolated enum AgentActivityEventKind: String, Sendable, Hashable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case sessionStop = "session_stop"
    case sessionPause = "session_pause"
    case sessionResume = "session_resume"
    case sessionIdle = "session_idle"
    case observe
    case act
    case policyReject = "policy_reject"
    case consentRequest = "consent_request"
    case consentDecide = "consent_decide"
    case error
}

/// A stored frame: an event's before or after image.
public nonisolated struct AgentActivityFrameRef: Sendable, Hashable {
    public let blob: String
    public let width: Int
    public let height: Int
    /// Retention removed the pixels; the event stays.
    public var expired: Bool

    public init(blob: String, width: Int, height: Int, expired: Bool = false) {
        self.blob = blob
        self.width = width
        self.height = height
        self.expired = expired
    }
}

/// One row of a session's event log.
public nonisolated struct AgentActivityEvent: Sendable, Hashable, Identifiable {
    public var id: UInt64 { seq }
    public let seq: UInt64
    public let time: Date
    public let kind: AgentActivityEventKind
    /// Tool name as the agent called it (`click`, `type_text`, ...).
    public let tool: String?
    /// App and window title, already redacted by the host.
    public let target: String?
    public let ok: Bool
    public let errorCode: String?
    public let durationMs: Int?
    /// Typed text the host replaced by its length (C5).
    public let redactedTextLength: Int?
    public let beforeFrame: AgentActivityFrameRef?
    public let afterFrame: AgentActivityFrameRef?
    /// Click position as a fraction of the frame (0...1, top-left origin).
    public let clickPoint: CGPoint?

    public init(
        seq: UInt64, time: Date, kind: AgentActivityEventKind, tool: String? = nil, target: String? = nil,
        ok: Bool = true, errorCode: String? = nil, durationMs: Int? = nil, redactedTextLength: Int? = nil,
        beforeFrame: AgentActivityFrameRef? = nil, afterFrame: AgentActivityFrameRef? = nil, clickPoint: CGPoint? = nil
    ) {
        self.seq = seq
        self.time = time
        self.kind = kind
        self.tool = tool
        self.target = target
        self.ok = ok
        self.errorCode = errorCode
        self.durationMs = durationMs
        self.redactedTextLength = redactedTextLength
        self.beforeFrame = beforeFrame
        self.afterFrame = afterFrame
        self.clickPoint = clickPoint
    }

    /// The frame the timeline shows for this event (after, else before).
    public var displayFrame: AgentActivityFrameRef? { afterFrame ?? beforeFrame }
}
