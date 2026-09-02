public import Foundation
import CryptoKit

/// Attach, detach, restore, and ``remote.herdr.*`` gating.
///
/// Mirrors ``RemoteTmuxController+Attach`` onto the Herdr Unix socket.
/// No AppKit. No SSH / ControlMaster / ``tmux -CC``. Host close
/// always detaches. Restore reattaches; it never replays a stale tree.
public enum RemoteHerdrLifecycle {
    /// Catalog key twin of tmux ``betaFeatures.remoteTmux``.
    public static let settingKey = "remoteHerdrMirror.beta.enabled"

    /// Control-socket methods twin of ``remote.tmux.*``.
    public static let socketMethods: [String] = [
        "remote.herdr.sessions",
        "remote.herdr.attach",
        "remote.herdr.mirror",
        "remote.herdr.window",
        "remote.herdr.detach",
        "remote.herdr.state",
        "remote.herdr.pane_surfaces",
        "remote.herdr.pane_grids",
    ]

    public static let postReseed = "reseed"
    public static let postApplyClientSize = "apply_client_size"

    /// Stable endpoint id (tmux ``connectionHash``). Never log the path.
    public static func endpointHash(_ socketPath: String) -> String {
        let digest = SHA256.hash(data: Data(socketPath.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reject control / format scalars at the socket trust boundary.
    public static func hasHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
        }
    }

    /// Accept an absolute Unix socket path; reject injection-shaped values.
    public static func validateSocketPath(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.hasPrefix("/"),
              !raw.hasPrefix("-"),
              !hasHiddenCharacter(raw)
        else { return nil }
        return raw
    }

    /// Require a non-empty session id after trim.
    public static func validateSessionName(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    /// Decode the beta flag the way tmux reads ``remoteTmux``.
    public static func decodeBeta(_ value: Any?, default defaultValue: Bool = false) -> Bool {
        switch value {
        case nil:
            return defaultValue
        case let flag as Bool:
            return flag
        case let number as Int where number == 0 || number == 1:
            return number == 1
        case let text as String:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return defaultValue
            }
        default:
            return defaultValue
        }
    }

    /// Reuse a live connection; replace a dead one; otherwise start.
    ///
    /// - Parameter started: When no process exists, always `"start"` (retry-safe
    ///   even if a prior attempt set `started == false`). When a process exists
    ///   and has not exited, require `started` so we do not treat an unowned
    ///   pid as a reusable cmux connection.
    public static func connectionAction(started: Bool, exited: Bool, exists: Bool) -> String {
        guard exists else { return "start" }
        if exited { return "replace" }
        return started ? "reuse" : "start"
    }

    /// Never insert a connection that failed to start.
    public static func mayCacheConnection(started: Bool, exited: Bool) -> Bool {
        started && !exited
    }

    /// Reconnect reseeds every pane; first connect applies the stored grid.
    public static func postAttachAction(replacedDead: Bool) -> String {
        replacedDead ? postReseed : postApplyClientSize
    }

    /// Every host close detaches. Herdr has no safe kill-session analogue.
    public static func hostClosePolicy(_ source: String) -> String {
        switch source {
        case "last_workspace_tab", "window_quit", "app_terminate",
             "explicit_detach", "host_tab", "host_panel":
            return "detach"
        default:
            return "noop"
        }
    }

    /// Tmux ``pane_grids`` render contract: exact on the split axis, fill on the other.
    public static func gridMatch(
        assignedCols: Int,
        assignedRows: Int,
        renderedCols: Int,
        renderedRows: Int,
        exactCols: Bool,
        exactRows: Bool
    ) -> Bool {
        let colsOK = exactCols ? renderedCols == assignedCols : renderedCols >= assignedCols
        let rowsOK = exactRows ? renderedRows == assignedRows : renderedRows >= assignedRows
        return colsOK && rowsOK
    }
}

/// Window-routing intent, preserved across the discover await.
public struct RemoteHerdrAttachWindowTarget: Hashable, Sendable {
    public var kind: String
    public var windowID: String?

    public init(kind: String, windowID: String? = nil) {
        self.kind = kind
        self.windowID = windowID
    }

    /// Resolve the live destination; existing-host affinity wins.
    public func resolve(
        existingMirrorWindowID: String?,
        activeWindowID: String?,
        isLive: (String) -> Bool
    ) -> String? {
        if let existing = existingMirrorWindowID, isLive(existing) {
            return existing
        }
        switch kind {
        case "dedicated_new_window":
            return nil
        case "explicit":
            if let windowID, isLive(windowID) { return windowID }
            return nil
        case "unresolved_explicit":
            return nil
        case "contextual":
            if let windowID, isLive(windowID) { return windowID }
            if let activeWindowID, isLive(activeWindowID) { return activeWindowID }
            return nil
        default:
            return nil
        }
    }

    /// Parse socket routing the way ``remoteTmuxAttachWindowTarget`` does.
    public static func fromParams(_ params: [String: Any], dedicated: Bool = false) -> RemoteHerdrAttachWindowTarget {
        if dedicated {
            return RemoteHerdrAttachWindowTarget(kind: "dedicated_new_window")
        }
        if params.keys.contains("window_id") {
            guard let text = params["window_id"] as? String, !text.isEmpty else {
                return RemoteHerdrAttachWindowTarget(kind: "unresolved_explicit")
            }
            return RemoteHerdrAttachWindowTarget(kind: "explicit", windowID: text)
        }
        if let preferred = params["preferred_window_id"] as? String, !preferred.isEmpty {
            return RemoteHerdrAttachWindowTarget(
                kind: "contextual",
                windowID: preferred
            )
        }
        if params.keys.contains("preferred_window_id") {
            // Non-string preferred ids fail closed rather than coercing.
            return RemoteHerdrAttachWindowTarget(kind: "contextual")
        }
        return RemoteHerdrAttachWindowTarget(kind: "contextual")
    }
}

/// One Herdr session from ``session.snapshot``.
public struct RemoteHerdrDiscoveredSession: Hashable, Sendable {
    public var sessionID: String
    public var name: String
    public var windowCount: Int
    public var attached: Bool

    public init(sessionID: String, name: String, windowCount: Int = 0, attached: Bool = false) {
        self.sessionID = sessionID
        self.name = name
        self.windowCount = windowCount
        self.attached = attached
    }

    /// Serialize one session for ``remote.herdr.sessions``.
    public func payload() -> [String: Any] {
        [
            "id": sessionID,
            "name": name,
            "windows": windowCount,
            "attached": attached,
        ]
    }
}

/// One mirrored Herdr session (tmux session-mirror workspace).
public struct RemoteHerdrMirrorRecord: Hashable, Sendable {
    public var sessionID: String
    public var windowID: String
    public var workspaceID: String?

    public init(sessionID: String, windowID: String, workspaceID: String?) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.workspaceID = workspaceID
    }
}

/// Pure attach decision (no AppKit, no socket I/O).
public struct RemoteHerdrAttachPlan: Hashable, Sendable {
    public var outcome: String
    public var windowID: String?
    public var createWindow: Bool
    public var sessionsToMirror: [String]
    public var sessionsToReuse: [String]
    public var purgeSessionIDs: [String]
    public var moveWorkspaceIDs: [String]
    public var postAttach: String?
    public var discardWindowOnFail: Bool
    public var activate: Bool
    public var reason: String?

    public init(
        outcome: String,
        windowID: String? = nil,
        createWindow: Bool = false,
        sessionsToMirror: [String] = [],
        sessionsToReuse: [String] = [],
        purgeSessionIDs: [String] = [],
        moveWorkspaceIDs: [String] = [],
        postAttach: String? = nil,
        discardWindowOnFail: Bool = false,
        activate: Bool = false,
        reason: String? = nil
    ) {
        self.outcome = outcome
        self.windowID = windowID
        self.createWindow = createWindow
        self.sessionsToMirror = sessionsToMirror
        self.sessionsToReuse = sessionsToReuse
        self.purgeSessionIDs = purgeSessionIDs
        self.moveWorkspaceIDs = moveWorkspaceIDs
        self.postAttach = postAttach
        self.discardWindowOnFail = discardWindowOnFail
        self.activate = activate
        self.reason = reason
    }
}

/// Last successful attach. Host persists this; the planner only reads it.
public struct RemoteHerdrRestoreRecord: Hashable, Sendable {
    public var endpointHash: String
    public var socketPath: String
    public var sessionIDs: [String]
    public var targetKind: String
    public var windowID: String?

    public init(
        endpointHash: String,
        socketPath: String,
        sessionIDs: [String],
        targetKind: String,
        windowID: String? = nil
    ) {
        self.endpointHash = endpointHash
        self.socketPath = socketPath
        self.sessionIDs = sessionIDs
        self.targetKind = targetKind
        self.windowID = windowID
    }

    /// JSON-safe persist payload. ``replay_tree`` is never a field.
    public func dictionary() -> [String: Any] {
        var payload: [String: Any] = [
            "endpoint_hash": endpointHash,
            "socket_path": socketPath,
            "session_ids": sessionIDs,
            "target_kind": targetKind,
            "mode": "reattach",
        ]
        if let windowID {
            payload["window_id"] = windowID
        }
        return payload
    }

    /// Load a persist payload. Rejects a stale-tree replay marker.
    public static func fromDictionary(_ payload: [String: Any]) -> RemoteHerdrRestoreRecord? {
        if payload["mode"] as? String == "replay_tree" { return nil }
        guard let socket = RemoteHerdrLifecycle.validateSocketPath(payload["socket_path"] as? String),
              let endpoint = payload["endpoint_hash"] as? String, !endpoint.isEmpty,
              let kind = payload["target_kind"] as? String, !kind.isEmpty,
              let sessions = payload["session_ids"] as? [String], !sessions.isEmpty
        else { return nil }
        return RemoteHerdrRestoreRecord(
            endpointHash: endpoint,
            socketPath: socket,
            sessionIDs: sessions,
            targetKind: kind,
            windowID: payload["window_id"] as? String
        )
    }
}

/// Re-entrant attach guard (tmux ``RemoteTmuxWindowRegistry``).
public struct RemoteHerdrAttachRegistry: Sendable {
    private var pending: Set<String> = []

    public init() {}

    /// Record an in-flight attach; ``false`` if one is already running.
    public mutating func beginAttach(_ endpoint: String) -> Bool {
        if pending.contains(endpoint) { return false }
        pending.insert(endpoint)
        return true
    }

    /// Clear the in-flight marker (the ``defer``).
    public mutating func endAttach(_ endpoint: String) {
        pending.remove(endpoint)
    }

    /// Whether ``endpoint`` currently has an attach in flight.
    public func isAttaching(_ endpoint: String) -> Bool {
        pending.contains(endpoint)
    }
}

public enum RemoteHerdrAttachPlanner {
    /// Decide attach the way ``RemoteTmuxController.attachHost`` does.
    ///
    /// Pass ``sessions == nil`` for the preflight (reject a guaranteed-invalid
    /// destination *before* discovery). Dedicated windows are created only
    /// after a non-empty discovery so a failed attach never leaves empty chrome.
    public static func plan(
        target: RemoteHerdrAttachWindowTarget,
        enabled: Bool,
        appReady: Bool,
        alreadyAttaching: Bool,
        existingMirrorWindowID: String?,
        activeWindowID: String?,
        liveWindows: [String],
        sessions: [RemoteHerdrDiscoveredSession]? = nil,
        mirrors: [RemoteHerdrMirrorRecord] = [],
        liveSessionIDs: [String] = [],
        activate: Bool = false,
        mirroredWorkspaceIDs: [String]? = nil
    ) -> RemoteHerdrAttachPlan {
        if !enabled {
            return RemoteHerdrAttachPlan(outcome: "disabled", reason: "beta_disabled")
        }
        if !appReady {
            return RemoteHerdrAttachPlan(outcome: "unreachable", reason: "app_not_ready")
        }
        if alreadyAttaching {
            return RemoteHerdrAttachPlan(outcome: "already_attaching", reason: "reentrant")
        }
        let live = Set(liveWindows)
        let isLive: (String) -> Bool = { live.contains($0) }
        if target.kind != "dedicated_new_window" {
            if target.resolve(
                existingMirrorWindowID: existingMirrorWindowID,
                activeWindowID: activeWindowID,
                isLive: isLive
            ) == nil {
                return RemoteHerdrAttachPlan(outcome: "invalid_target", reason: "window_unresolved")
            }
        }
        guard let sessions else {
            return RemoteHerdrAttachPlan(outcome: "discover")
        }
        if sessions.isEmpty {
            return RemoteHerdrAttachPlan(outcome: "no_sessions", reason: "empty_discovery")
        }
        let dead = mirrors.compactMap { $0.workspaceID == nil ? $0.sessionID : nil }
        let liveRecords = mirrors.filter { $0.workspaceID != nil }
        let liveIDs = Set(liveSessionIDs)
        let discovered = sessions.map(\.sessionID)

        let createWindow = target.kind == "dedicated_new_window"
        var windowID: String?
        var moveIDs: [String] = []
        if createWindow {
            moveIDs = liveRecords.compactMap(\.workspaceID)
        } else {
            windowID = target.resolve(
                existingMirrorWindowID: existingMirrorWindowID,
                activeWindowID: activeWindowID,
                isLive: isLive
            )
            if windowID == nil {
                return RemoteHerdrAttachPlan(outcome: "invalid_target", reason: "window_lost")
            }
        }

        var reuse: [String] = []
        var create: [String] = []
        for sessionID in discovered {
            if liveIDs.contains(sessionID) && !dead.contains(sessionID) {
                reuse.append(sessionID)
            } else {
                create.append(sessionID)
            }
        }

        if let mirroredWorkspaceIDs, mirroredWorkspaceIDs.isEmpty {
            return RemoteHerdrAttachPlan(
                outcome: "failed_empty",
                windowID: windowID,
                createWindow: createWindow,
                purgeSessionIDs: dead,
                discardWindowOnFail: createWindow,
                reason: "no_workspaces"
            )
        }

        let outcome: String
        let post: String?
        if create.isEmpty && !reuse.isEmpty {
            outcome = "reused"
            post = dead.isEmpty ? nil : RemoteHerdrLifecycle.postReseed
        } else {
            outcome = "mirrored"
            post = RemoteHerdrLifecycle.postAttachAction(replacedDead: !dead.isEmpty && reuse.isEmpty)
        }
        return RemoteHerdrAttachPlan(
            outcome: outcome,
            windowID: windowID,
            createWindow: createWindow,
            sessionsToMirror: create,
            sessionsToReuse: reuse,
            purgeSessionIDs: dead,
            moveWorkspaceIDs: createWindow ? moveIDs : [],
            postAttach: post,
            discardWindowOnFail: createWindow,
            activate: activate
        )
    }

    /// Reattach after a cmux restart. Never returns ``replay_tree``.
    public static func planRestore(
        _ record: RemoteHerdrRestoreRecord,
        enabled: Bool,
        appReady: Bool,
        sessions: [RemoteHerdrDiscoveredSession],
        liveWindows: [String],
        activeWindowID: String? = nil
    ) -> RemoteHerdrAttachPlan {
        if !enabled {
            return RemoteHerdrAttachPlan(outcome: "disabled", reason: "beta_disabled")
        }
        let target: RemoteHerdrAttachWindowTarget
        if let windowID = record.windowID, liveWindows.contains(windowID) {
            target = RemoteHerdrAttachWindowTarget(kind: "explicit", windowID: windowID)
        } else if record.targetKind == "dedicated_new_window" {
            target = RemoteHerdrAttachWindowTarget(kind: "dedicated_new_window")
        } else {
            target = RemoteHerdrAttachWindowTarget(kind: "contextual")
        }
        let plan = Self.plan(
            target: target,
            enabled: enabled,
            appReady: appReady,
            alreadyAttaching: false,
            existingMirrorWindowID: nil,
            activeWindowID: activeWindowID,
            liveWindows: liveWindows,
            sessions: sessions,
            activate: true
        )
        if plan.outcome == "mirrored" || plan.outcome == "reused" {
            return RemoteHerdrAttachPlan(
                outcome: "mirrored",
                windowID: plan.windowID,
                createWindow: plan.createWindow,
                sessionsToMirror: plan.sessionsToMirror.isEmpty
                    ? sessions.map(\.sessionID) : plan.sessionsToMirror,
                postAttach: RemoteHerdrLifecycle.postReseed,
                discardWindowOnFail: plan.discardWindowOnFail,
                activate: true,
                reason: "restore_reattach"
            )
        }
        return plan
    }

    /// First live window that already owns a mirror for this endpoint.
    public static func existingMirrorWindow(
        _ mirrors: [RemoteHerdrMirrorRecord],
        liveWindows: [String]
    ) -> String? {
        let live = Set(liveWindows)
        return mirrors.first { $0.workspaceID != nil && live.contains($0.windowID) }?.windowID
    }

    /// Drop mirrors whose workspace died without a controller detach.
    public static func purgeDead(_ mirrors: [RemoteHerdrMirrorRecord]) -> [RemoteHerdrMirrorRecord] {
        mirrors.filter { $0.workspaceID != nil }
    }

    /// Validate a ``remote.herdr.*`` call at the socket trust boundary.
    public static func dispatch(
        method: String,
        params: [String: Any] = [:],
        enabled: Bool
    ) -> [String: Any] {
        if !RemoteHerdrLifecycle.socketMethods.contains(method) {
            return ["ok": false, "code": "unknown_method"]
        }
        if !enabled {
            return ["ok": false, "code": "disabled"]
        }
        let socket = RemoteHerdrLifecycle.validateSocketPath(
            (params["socket"] as? String) ?? (params["socket_path"] as? String)
        )
        guard let socket else {
            return ["ok": false, "code": "invalid_params"]
        }
        let needsSession = [
            "remote.herdr.attach",
            "remote.herdr.detach",
            "remote.herdr.state",
            "remote.herdr.pane_surfaces",
            "remote.herdr.pane_grids",
        ].contains(method)
        var session: String?
        if needsSession {
            session = RemoteHerdrLifecycle.validateSessionName(params["session"] as? String)
            if session == nil {
                return ["ok": false, "code": "invalid_params"]
            }
        }
        let dedicated = method == "remote.herdr.window"
        let target = RemoteHerdrAttachWindowTarget.fromParams(params, dedicated: dedicated)
        return [
            "ok": true,
            "method": method,
            "socket": socket,
            "session": session as Any,
            "target_kind": target.kind,
            "activate": (params["activate"] as? Bool) ?? false,
        ]
    }
}
