public import CmuxNextAgentActivity
public import Foundation

/// One Computer Use session as the live preview card needs it: what links it to a chat, the app it
/// drives, and whether it still runs. Any driver's sessions map to it.
public nonisolated struct ComputerUsePreviewSession: Equatable, Sendable {
    public var id: String
    public var live: Bool
    /// The app it last acted on: its name, bundle id and process, as the driver named them (the
    /// legacy helper names only the process), and its window's title.
    public var app: String?
    public var bundleID: String?
    public var pid: Int32?
    public var windowTitle: String?
    /// The agent as the driver stamped it (`claude`, `codex`, `acp:<harness>`, `unknown`, ...).
    public var agentKind: String
    /// Ids that name the chat, when the driver attributed the session (computer-use.md section 3).
    public var acpSession: String?
    public var harnessSessionID: String?
    public var workspaceID: String?
    public var lastActionAt: Date
    /// Grows with each act or observe, so a list says when the session did something.
    public var steps: Int

    public init(id: String, live: Bool, app: String? = nil, bundleID: String? = nil, pid: Int32? = nil,
                windowTitle: String? = nil, agentKind: String = "unknown", acpSession: String? = nil,
                harnessSessionID: String? = nil, workspaceID: String? = nil, lastActionAt: Date, steps: Int = 0) {
        self.id = id
        self.live = live
        self.app = app
        self.bundleID = bundleID
        self.pid = pid
        self.windowTitle = windowTitle
        self.agentKind = agentKind
        self.acpSession = acpSession
        self.harnessSessionID = harnessSessionID
        self.workspaceID = workspaceID
        self.lastActionAt = lastActionAt
        self.steps = steps
    }

    /// Which app to look up for its display name and icon; nil when the driver named none.
    public var appKey: ComputerUsePreviewApp.Key? {
        guard bundleID != nil || pid != nil else { return nil }
        return ComputerUsePreviewApp.Key(bundleID: bundleID, pid: pid)
    }
}

/// The window a session acts on: its process and WindowServer id (the live capture streams it).
public typealias ComputerUsePreviewWindow = AgentActivityTargetWindow

/// Where a session's agent clicked last: a point in a window, as a fraction of it (0...1 from the
/// top left), the same window the live capture streams. The card draws its cursor there.
public nonisolated struct ComputerUsePreviewPointer: Equatable, Sendable {
    public var window: ComputerUsePreviewWindow
    public var x: Double
    public var y: Double
    /// The click's event in the session's log: a new one plays the click again.
    public var click: UInt64
    /// The window's width in points, when known: the card draws the cursor at the window's scale.
    public var windowWidth: Double?

    public init(window: ComputerUsePreviewWindow, x: Double, y: Double, click: UInt64, windowWidth: Double? = nil) {
        self.window = window
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.click = click
        self.windowWidth = windowWidth
    }
}

/// What a live preview source pushes.
public nonisolated enum ComputerUseLivePreviewUpdate: Sendable {
    /// Every session the driver knows now (replaces the last list).
    case sessions([ComputerUsePreviewSession])
    /// The newest frame of `session`, by an id the source loads (``ComputerUseLivePreviewSource/frame(_:)``),
    /// and when it was captured.
    case newestFrame(session: String, frame: String, at: Date)
    /// The window `session` acted on or read last.
    case window(session: String, ComputerUsePreviewWindow)
    /// Where `session`'s agent clicked last (a pixel click only: an accessibility click has no point).
    case pointer(session: String, ComputerUsePreviewPointer)
    /// `session`'s agent clicked (any click): its event in the session's log.
    case clicked(session: String, UInt64)
}

/// Where the live preview cards' data comes from: the sessions, each one's newest frame, and its
/// end. v1 reads the legacy helper's activity socket (``ComputerUseActivityPreviewSource``); a
/// driver that captures frames itself (ScreenCaptureKit in the helper host) plugs in here with no
/// change to the board, the card or the page.
@MainActor
public protocol ComputerUseLivePreviewSource: AnyObject {
    /// Starts pushing updates to `sink`; a source pushes, it never polls.
    func start(_ sink: @escaping @MainActor (ComputerUseLivePreviewUpdate) -> Void)
    /// Ends the pushes and drops what was started.
    func stop()
    /// Whether the card wants the newest frames of `session` (a source that pushes every frame anyway ignores it).
    func follow(session: String, _ on: Bool)
    /// Frame `frame` as a `data:image/...` URL, loaded off the main thread; nil when it is gone.
    func frame(_ frame: String) async -> String?
}

/// ``ComputerUseLivePreviewSource`` over the legacy cmux-cua helper's activity socket: the
/// `activity_subscribe` stream (``AgentActivitySocketSource``), each followed session's timeline
/// for its newest frame, and `activity_frame` thumbnails.
@MainActor
public final class ComputerUseActivityPreviewSource: ComputerUseLivePreviewSource {
    private let activity: AgentActivitySocketSource
    private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?

    /// The largest thumbnail taken, in base64 bytes (the helper's are about 320 px, tens of KB).
    nonisolated static let maximumFrameBytes = 4 << 20

    public init(configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?) {
        self.configuration = configuration
        activity = AgentActivitySocketSource(configuration: configuration)
    }

    public func start(_ sink: @escaping @MainActor (ComputerUseLivePreviewUpdate) -> Void) {
        activity.start { update in
            switch update {
            case .sessions(_, let sessions):
                sink(.sessions(sessions.map(Self.session)))
            case .events(let session, let events):
                if let window = events.last(where: { $0.window != nil })?.window { sink(.window(session: session, window)) }
                if let pointer = Self.pointer(events) { sink(.pointer(session: session, pointer)) }
                if let click = events.last(where: Self.isClick)?.seq { sink(.clicked(session: session, click)) }
                if let frame = Self.newestFrame(events) { sink(.newestFrame(session: session, frame: frame.id, at: frame.at)) }
            case .connection:
                break
            }
        }
    }

    public func stop() { activity.stop() }

    public func follow(session: String, _ on: Bool) { activity.follow(session: session, on) }

    public func frame(_ frame: String) async -> String? {
        guard let configuration = configuration() else { return nil }
        return await Self.thumbnail(configuration, blob: frame)
    }

    /// The newest frame of a batch of events that still has its pixels (after, else before), and
    /// its event's time (the helper captures an event's frames with the event).
    nonisolated static func newestFrame(_ events: [AgentActivityEvent]) -> (id: String, at: Date)? {
        guard let event = events.last(where: { $0.displayFrame.map { !$0.expired } ?? false }),
              let frame = event.displayFrame else { return nil }
        return (frame.blob, event.time)
    }

    /// The click tools: each plays the card cursor's click.
    nonisolated static let clickTools: Set<String> = ["click", "double_click", "right_click", "drag"]

    nonisolated static func isClick(_ event: AgentActivityEvent) -> Bool {
        event.kind == .act && event.tool.map(clickTools.contains) == true
    }

    /// The newest click of a batch of events: its point in the window it targeted.
    nonisolated static func pointer(_ events: [AgentActivityEvent]) -> ComputerUsePreviewPointer? {
        guard let event = events.last(where: { $0.clickPoint != nil && $0.window != nil }),
              let point = event.clickPoint, let window = event.window else { return nil }
        return ComputerUsePreviewPointer(window: window, x: point.x, y: point.y, click: event.seq)
    }

    nonisolated static func session(_ value: AgentActivitySession) -> ComputerUsePreviewSession {
        ComputerUsePreviewSession(id: value.id, live: value.status.isLive, app: value.targetApp ?? value.targetApps.last,
                                  bundleID: value.targetBundleID, pid: value.targetPID, windowTitle: value.targetWindowTitle,
                                  agentKind: value.agentKind, acpSession: value.acpSession,
                                  harnessSessionID: value.harnessSessionID, workspaceID: value.workspaceID,
                                  lastActionAt: value.lastActionAt, steps: value.acts + value.observes)
    }

    /// The thumbnail of `blob` as a `data:` URL, read and checked off the main thread.
    @concurrent nonisolated private static func thumbnail(_ configuration: AgentActivitySocketSource.Configuration,
                                                          blob: String) async -> String? {
        guard let reply = try? await CuaSocketClient(configuration: configuration)
            .send("activity_frame", ["blob": blob, "size": "thumb"], deadline: .seconds(5)),
              let base64 = reply["data_base64"] as? String, !base64.isEmpty, base64.utf8.count <= maximumFrameBytes,
              let data = Data(base64Encoded: base64) else { return nil }
        // A window frame's black corners (no alpha in the JPEG) cleared to the window's own outline.
        if let rounded = ComputerUseFrameCorners.clearingCorners(data) {
            return "data:image/png;base64,\(rounded.base64EncodedString())"
        }
        let mime = (reply["mime"] as? String).flatMap { ["image/jpeg", "image/png", "image/webp"].contains($0) ? $0 : nil }
        return "data:\(mime ?? "image/jpeg");base64,\(base64)"
    }
}
