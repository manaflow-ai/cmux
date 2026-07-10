public import Foundation
public import GhosttyKit

/// Content-free renderer activity emitted by Ghostty's renderer thread.
public enum TerminalRendererProfilingEvent: String, Sendable {
    case updateFrameBegin = "update-frame-begin"
    case updateFrameEnd = "update-frame-end"
    case drawFrameBegin = "draw-frame-begin"
    case drawFrameEnd = "draw-frame-end"

    public init?(_ event: ghostty_renderer_event_e) {
        switch event {
        case GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_BEGIN: self = .updateFrameBegin
        case GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END: self = .updateFrameEnd
        case GHOSTTY_RENDERER_EVENT_DRAW_FRAME_BEGIN: self = .drawFrameBegin
        case GHOSTTY_RENDERER_EVENT_DRAW_FRAME_END: self = .drawFrameEnd
        default: return nil
        }
    }

    var interval: TerminalRendererEventInterval {
        switch self {
        case .updateFrameBegin, .updateFrameEnd: .updateFrame
        case .drawFrameBegin, .drawFrameEnd: .drawFrame
        }
    }

    var isBegin: Bool {
        switch self {
        case .updateFrameBegin, .drawFrameBegin: true
        case .updateFrameEnd, .drawFrameEnd: false
        }
    }
}

enum TerminalRendererEventInterval: Equatable, Hashable, Sendable {
    case updateFrame
    case drawFrame
}

enum TerminalRendererEventPairingAction: Equatable, Sendable {
    case begin(TerminalRendererEventInterval)
    case end(TerminalRendererEventInterval)
}

struct TerminalRendererEventPairing: Sendable {
    private var active: Set<TerminalRendererEventInterval> = []

    mutating func consume(_ event: TerminalRendererProfilingEvent) -> TerminalRendererEventPairingAction? {
        let interval = event.interval
        if event.isBegin {
            guard active.insert(interval).inserted else { return nil }
            return .begin(interval)
        }
        guard active.remove(interval) != nil else { return nil }
        return .end(interval)
    }
}

/// Privacy-closed payload for one exact Ghostty renderer event.
public struct TerminalRendererEventProfilingMetadata: Equatable, Sendable {
    public let identity: TerminalRendererProfilingIdentity
    public let visible: Bool
    public let focused: Bool
    public let event: TerminalRendererProfilingEvent

    public init(
        identity: TerminalRendererProfilingIdentity,
        visible: Bool,
        focused: Bool,
        event: TerminalRendererProfilingEvent
    ) {
        self.identity = identity
        self.visible = visible
        self.focused = focused
        self.event = event
    }

    public var details: String {
        "workspace=\(identity.workspaceId.uuidString) " +
            "surface=\(identity.surfaceId.uuidString) " +
            "visible=\(visible ? 1 : 0) focused=\(focused ? 1 : 0) " +
            "event=\(event.rawValue)"
    }
}
