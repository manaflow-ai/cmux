import CmuxNextWakeups
import Foundation

/// View or control (the toolbar toggle). Control sends input; view only
/// watches and shows the remote cursor.
public nonisolated enum RemoteControlMode: String, Sendable, Hashable, CaseIterable, Codable {
    case view
    case control
}

/// How the toolbar offers control: the View / Control toggle, or (a Cloud machine's desktop,
/// which opens watching the agent) one Take over / Hand back button.
public nonisolated enum RemoteModeControl: Sendable, Hashable {
    case toggle
    case takeOver
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
    /// A Cloud machine's desktop, reached only over the app's own Cloud tunnel: the state card
    /// says so instead of the phase-1 development note.
    public var viaCloudTunnel = false
    /// Connecting again after a session that showed frames: keep that last frame with no card.
    /// Cleared by the next frame shown.
    public var reconnecting = false
    /// When the current reconnect started (nil while not reconnecting), for elapsed diagnostics.
    public var reconnectingSince: ContinuousClock.Instant?
    /// The reconnect has run for ``reconnectNoticeDelay``. Duration alone never shows a card.
    public var reconnectNoticeDue = false
    /// The elapsed reconnect diagnostic threshold. Crossing it does not show a notice.
    public static let reconnectNoticeDelay: Duration = QuietHold.connectionDelay
    /// When the current first connect started (nil while none is coming up, or for a state no reducer
    /// stamped): under ``connectNoticeDelay`` nothing shows over the empty pane, so a connect that lands
    /// fast draws no "Connecting to …" card at all.
    public var connectingSince: ContinuousClock.Instant?
    /// The first connect has run for ``connectNoticeDelay``: the connecting card (with Cancel) shows now.
    public var connectNoticeDue = false
    /// How long a first connect stays silent (``QuietHold/comingUpDelay``). The card has Cancel, so it may
    /// show once this short wait is over; a reconnect waits the longer ``reconnectNoticeDelay``.
    public static let connectNoticeDelay: Duration = QuietHold.comingUpDelay
    /// The toggle, or Take over / Hand back.
    public var modeControl = RemoteModeControl.toggle
    /// Whether the path counts as high latency, held so one sample does not flip it.
    public var latency = RemoteLatencyHold()

    public init(hostName: String, requestedMode: RemoteControlMode = .control, interactiveMaxRttMs: Int = 80) {
        self.hostName = hostName
        self.requestedMode = requestedMode
        self.interactiveMaxRttMs = interactiveMaxRttMs
    }

    public var sessionState: RemoteSessionState { status?.state ?? .connecting }

    /// The path's RTT has stayed above the interactive limit (section 2.1) for
    /// ``RemoteLatencyHold/sustain``; it counts as low again only after as long under it.
    public var isHighLatency: Bool { latency.high }

    /// The latest RTT sample is above the interactive limit (``latency`` holds it over time).
    public var sampleOverLimit: Bool {
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
        case .connecting: quietConnecting ? nil : .connecting
        case .waitingForConsent: .waitingForConsent
        case .streaming: hasFrame || quietConnecting ? nil : .connecting
        case let .ended(reason): .ended(reason)
        }
    }

    /// Automatic reconnect keeps the last frame until recovery or an actionable ended state.
    public var quietReconnect: Bool { reconnecting }

    /// A first connect (no picture yet, not a reconnect) that is still coming up: connecting, or
    /// streaming before its first frame.
    public var comingUp: Bool {
        guard !reconnecting, !hasFrame else { return false }
        return sessionState == .connecting || sessionState == .streaming
    }

    /// A first connect under ``connectNoticeDelay`` (stamped by the reducer): nothing to say yet.
    public var quietConnect: Bool { comingUp && connectingSince != nil && !connectNoticeDue }

    /// Either connect is still under its quiet time: no card, and the path badge does not say "connecting".
    public var quietConnecting: Bool { quietReconnect || quietConnect }

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

    /// Upstream media as the transport reports it; nothing once the session ended.
    public var upstream: RemoteUpstreamStatus {
        isEndedState ? RemoteUpstreamStatus() : status?.upstream ?? RemoteUpstreamStatus()
    }

    /// The per-kind share buttons: only while streaming from a host that offers upstream media.
    public var showsUpstreamButtons: Bool { sessionState == .streaming && upstream.offered }

    /// The kinds the indicator shows (each holds consent), in a fixed order.
    public var upstreamIndicator: [RemoteUpstreamKind] {
        RemoteUpstreamKind.allCases.filter(upstream.active.contains)
    }

    private var isEndedState: Bool {
        if case .ended = sessionState { true } else { false }
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
