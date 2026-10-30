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

/// Which stored size of a frame to read (`activity_frame` `size`). The host
/// keeps a thumbnail (about 320 px long edge) for every event with pixels; a
/// full frame only when the session records `events+frames` or `video`.
public nonisolated enum AgentActivityFrameSize: String, Sendable, Hashable {
    case thumb
    case full
}

/// A frame's encoded bytes as the host sent them, passed to the page as is
/// (no decode or re-encode in the App).
public nonisolated struct AgentActivityFrameData: Sendable, Hashable {
    /// `image/jpeg`, `image/png` or another `image/` type.
    public let mime: String
    public let base64: String

    public init(mime: String, base64: String) {
        self.mime = mime
        self.base64 = base64
    }

    /// The frame as a `data:` URL for an `<img>`.
    public var dataURL: String { "data:\(mime);base64,\(base64)" }
}

/// The window an event acted on or read, as the host named it: its process and WindowServer id.
public nonisolated struct AgentActivityTargetWindow: Sendable, Hashable {
    public let pid: Int32
    public let windowID: UInt32

    public init(pid: Int32, windowID: UInt32) {
        self.pid = pid
        self.windowID = windowID
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
    /// The window the event targeted, when the host named both its process and its id.
    public let window: AgentActivityTargetWindow?

    public init(
        seq: UInt64, time: Date, kind: AgentActivityEventKind, tool: String? = nil, target: String? = nil,
        ok: Bool = true, errorCode: String? = nil, durationMs: Int? = nil, redactedTextLength: Int? = nil,
        beforeFrame: AgentActivityFrameRef? = nil, afterFrame: AgentActivityFrameRef? = nil, clickPoint: CGPoint? = nil,
        window: AgentActivityTargetWindow? = nil
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
        self.window = window
    }

    /// The frame the timeline shows for this event (after, else before).
    public var displayFrame: AgentActivityFrameRef? { afterFrame ?? beforeFrame }
}
