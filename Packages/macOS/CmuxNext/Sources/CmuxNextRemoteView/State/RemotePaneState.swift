import Foundation

/// View or control (the toolbar toggle). Control sends input; view only
/// watches and shows the remote cursor.
public nonisolated enum RemoteControlMode: String, Sendable, Hashable, CaseIterable, Codable {
    case view
    case control
}

/// Everything the pane shows, derived only from the transport's latest
/// status and the viewer's choices. Pure value: `RemotePaneReducer` is the
/// only writer and the tests drive it without views.
public nonisolated struct RemotePaneState: Sendable, Hashable {
    public var hostName: String
    /// The latest transport status; nil before the first one.
    public var status: RemoteViewStatus?
    /// What the viewer asked for with the toggle.
    public var requestedMode: RemoteControlMode
    /// "Control Anyway" on a high-latency path; cleared when a new session starts.
    public var controlDespiteLatency = false
    /// `remoteDesktop.interactiveMaxRttMs`.
    public var interactiveMaxRttMs: Int
    /// A decoded frame was shown in this session (ended states keep it).
    public var hasFrame = false

    public init(hostName: String, requestedMode: RemoteControlMode = .control, interactiveMaxRttMs: Int = 80) {
        self.hostName = hostName
        self.requestedMode = requestedMode
        self.interactiveMaxRttMs = interactiveMaxRttMs
    }

    public var sessionState: RemoteSessionState { status?.state ?? .connecting }

    /// The path's RTT is above the interactive limit (section 2.1).
    public var isHighLatency: Bool {
        guard let rtt = status?.rttMs else { return false }
        return rtt > interactiveMaxRttMs
    }

    /// The mode in force: control only while streaming, and on a slow path
    /// only after "Control Anyway".
    public var effectiveMode: RemoteControlMode {
        guard sessionState == .streaming, requestedMode == .control else { return .view }
        return isHighLatency && !controlDespiteLatency ? .view : .control
    }

    /// The centered card over the pane, if any.
    public var overlay: RemotePaneOverlay? {
        switch sessionState {
        case .connecting: .connecting
        case .waitingForConsent: .waitingForConsent
        case .streaming: hasFrame ? nil : .connecting
        case let .ended(reason): .ended(reason)
        }
    }

    /// The "View only: high latency" banner with "Control Anyway".
    public var showsLatencyBanner: Bool {
        sessionState == .streaming && requestedMode == .control && isHighLatency && !controlDespiteLatency
    }

    /// The toolbar shows the View/Control toggle, display, quality and Stop
    /// only while a session is live.
    public var showsSessionControls: Bool {
        switch sessionState {
        case .streaming, .waitingForConsent: true
        case .connecting, .ended: false
        }
    }

    /// The toolbar stays pinned (not hover-only) while there is no live picture.
    public var pinsToolbar: Bool { overlay != nil }
}

/// The state card over the pane.
public nonisolated enum RemotePaneOverlay: Sendable, Hashable {
    case connecting
    case waitingForConsent
    case ended(RemoteSessionEnd)
}
