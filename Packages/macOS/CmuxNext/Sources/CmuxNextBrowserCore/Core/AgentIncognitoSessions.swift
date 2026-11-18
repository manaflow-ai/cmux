public import Foundation
import Observation

/// Agent sessions' own incognito stores (opt-in: decision D1 keeps the person's login as the agents' default;
/// "Go with (a). Keep the person's login as the default (D1, cmux#13742), and add an opt-in per-session in-memory
/// profile: tabs.open/session.configure {incognito:true} through OffTheRecordProfiles, dropped when the session ends.").
///
/// A session that asks for incognito gets one `OffTheRecordProfiles` profile of its own and one incognito workspace,
/// made in the background in an incognito window of its own that never comes forward (the App's
/// `WindowManager+Incognito`). Its tabs use that profile, never the person's or the person's shared incognito
/// one, and nothing moves into or out of the workspace (``crosses(from:to:)``, ``crosses(_:toWindow:)``). The
/// session's end closes the workspace, then ends the profile: Chromium releases its in-memory contexts
/// (`CEFRuntime.adopt(stores:)`) and WebKit drops its non-persistent store (`WebKitProfileStore`).
///
/// Observable: the browser host's tab list reads ``session(ofWorkspace:)`` to announce only these incognito tabs.
@MainActor @Observable
public final class AgentIncognitoSessions {
    public struct Session: Equatable, Sendable {
        /// The session's own off-the-record profile.
        public let profile: BrowserProfileID
        /// The background incognito window that shows its workspace.
        public let window: String
        /// Its workspace, once the daemon made it.
        public var workspace: String?
    }

    /// Live sessions, by the host's session id.
    public private(set) var sessions: [String: Session] = [:]
    /// The session of each workspace a live session made.
    private var sessionByWorkspace: [String: String] = [:]
    /// Each session workspace's profile, kept after the session ended: a late page of a closing workspace still
    /// gets that ended, in-memory profile (`OffTheRecordProfiles.isOffTheRecord`), never a persistent one.
    private var profiles: [String: BrowserProfileID] = [:]
    /// Sessions whose workspace is being created (membership holds new ephemeral workspaces meanwhile).
    public private(set) var creating: Set<String> = []
    /// The workspace create in flight for each session (a second tab waits for the first's workspace).
    @ObservationIgnored public var pendingCreates: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let offTheRecord: OffTheRecordProfiles
    /// Closes a session's workspace and returns once it is closed (the App's `closeAgentWorkspace`).
    @ObservationIgnored public var closeWorkspace: @MainActor (String) async -> Void

    public init(offTheRecord: OffTheRecordProfiles, closeWorkspace: @escaping @MainActor (String) async -> Void) {
        self.offTheRecord = offTheRecord
        self.closeWorkspace = closeWorkspace
    }

    /// Session `id`, begun with its own profile and window on first use.
    @discardableResult
    public func begin(_ id: String) -> Session {
        if let session = sessions[id] { return session }
        let session = Session(profile: offTheRecord.begin(), window: UUID().uuidString.lowercased(), workspace: nil)
        sessions[id] = session
        return session
    }

    /// Session `id` (begun if new) with a new window id for its next workspace: the last one may have closed.
    public func newWindow(for id: String) -> String {
        let window = UUID().uuidString.lowercased(), session = begin(id)
        sessions[id] = Session(profile: session.profile, window: window, workspace: session.workspace)
        return window
    }

    /// The daemon made `workspace` for session `id`.
    public func attach(workspace: String, to id: String) {
        guard let session = sessions[id] else { return }
        if let old = session.workspace, old != workspace { sessionByWorkspace[old] = nil }
        sessions[id]?.workspace = workspace
        sessionByWorkspace[workspace] = id
        profiles[workspace] = session.profile
    }

    public func workspace(of id: String) -> String? { sessions[id]?.workspace }
    public func window(of id: String) -> String? { sessions[id]?.window }

    /// The live session that made `workspace`.
    public func session(ofWorkspace workspace: String) -> String? { sessionByWorkspace[workspace] }

    /// The profile of a session's workspace, also after the session ended.
    public func profile(forWorkspace workspace: String) -> BrowserProfileID? { profiles[workspace] }

    /// True while any session workspace has a profile here (a cheap test before a tab's workspace lookup).
    public var holdsAny: Bool { !profiles.isEmpty }

    /// True when `windowID` is a live session's background window.
    public func isSessionWindow(_ windowID: String) -> Bool { session(ofWindow: windowID) != nil }

    /// The live session whose window is `windowID`.
    public func session(ofWindow windowID: String) -> String? { sessions.first { $0.value.window == windowID }?.key }

    public func beginCreating(_ id: String) { creating.insert(id) }
    public func endCreating(_ id: String) { creating.remove(id) }

    /// Whether moving content of workspace `source` into workspace `target` (nil: a new workspace, or unknown) takes
    /// it into or out of a session's workspace; nil when neither is a session's (the caller's own rules decide).
    public func crossing(from source: String?, to target: String?) -> Bool? {
        guard source.flatMap(session(ofWorkspace:)) != nil || target.flatMap(session(ofWorkspace:)) != nil else { return nil }
        return source == nil || target == nil || source != target
    }

    /// True when moving workspaces `ids` (or their content) into window `windowID` takes content into or out of a
    /// session's workspace or window.
    public func crosses(_ ids: [String], toWindow windowID: String) -> Bool {
        let target = session(ofWindow: windowID)
        return ids.contains { id in
            let source = session(ofWorkspace: id)
            return (source != nil || target != nil) && source != target
        }
    }

    /// Ends session `id`: its workspace closes, then its profile ends (every engine drops its data). Once.
    public func end(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        creating.remove(id)
        if let workspace = session.workspace {
            sessionByWorkspace[workspace] = nil
            await closeWorkspace(workspace)
        }
        offTheRecord.end(session.profile)
    }

    /// Ends every session (the host's link closed).
    public func endAll() async {
        for id in Array(sessions.keys) { await end(id) }
    }
}
