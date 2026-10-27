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

/// What a live preview source pushes.
public nonisolated enum ComputerUseLivePreviewUpdate: Sendable {
    /// Every session the driver knows now (replaces the last list).
    case sessions([ComputerUsePreviewSession])
    /// The newest frame of `session`, by an id the source loads (``ComputerUseLivePreviewSource/frame(_:)``).
    case newestFrame(session: String, frame: String)
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
                if let frame = Self.newestFrame(events) { sink(.newestFrame(session: session, frame: frame)) }
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

    /// The newest frame of a batch of events that still has its pixels (after, else before).
    nonisolated static func newestFrame(_ events: [AgentActivityEvent]) -> String? {
        events.last { $0.displayFrame.map { !$0.expired } ?? false }?.displayFrame?.blob
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
              Data(base64Encoded: base64) != nil else { return nil }
        let mime = (reply["mime"] as? String).flatMap { ["image/jpeg", "image/png", "image/webp"].contains($0) ? $0 : nil }
        return "data:\(mime ?? "image/jpeg");base64,\(base64)"
    }
}
