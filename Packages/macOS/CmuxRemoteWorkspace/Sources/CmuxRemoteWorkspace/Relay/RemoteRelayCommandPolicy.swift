public import Foundation

/// Authorization policy for commands arriving through a remote CLI relay
/// (GHSA-9vmv-3hjw-j28c).
///
/// The relay credential authenticates the remote host's SSH user, but
/// authentication alone must not grant control of the local Mac: the
/// credential is deliberately stored on the remote host, so anyone with code
/// execution as that user can complete the HMAC handshake. This policy is the
/// authorization boundary applied to every post-authentication command line
/// before the app's alias-aware rewriter ever sees it:
///
/// 1. **Deny by default.** Only the v2 JSON-RPC methods the remote `cmux` CLI
///    and remote agent hooks actually use are forwarded; everything else
///    (including arbitrary `cmux rpc` passthrough into local-only methods) is
///    denied.
/// 2. **Remote targets only.** Every workspace/surface/tab ID parameter must
///    name an object the remote session owns. The owned set is the union of
///    the relay's alias-map keys (remote-minted snapshot IDs) and values
///    (live local IDs, which the app writes into the remote shell's
///    environment, plus identity entries the app syncs for fresh sessions).
///    Unmapped local UUIDs, and non-UUID handles such as `surface:12` refs
///    (which would name local objects by index), are denied.
/// 3. **No command execution through a relay, period.** Command-bearing
///    parameters (`initial_command`, `command`, `tmux_start_command`,
///    `pane_start_command`) are denied on every method, and `surface.respawn`
///    is not allowlisted at all: the app respawns a plain SSH remote surface
///    by spawning the replacement terminal *locally* under the same surface
///    ID (`respawnTerminalSurface` falls through to the local login path), so
///    any relay-carried respawn converts an owned surface into a local shell
///    the remote can then type into. Remote tmux-mirror panes never register
///    relay aliases, so no remote-exec respawn case is lost. Methods that can
///    only mint local objects (`workspace.create`, `window.create`,
///    `workspace.group.create`/`new_workspace`/`delete`) are not on the
///    allowlist either, and content-creating methods (`surface.create`,
///    `surface.split`, `pane.create`) must name an explicit aliased remote
///    target so they cannot attach to whatever local workspace happens to be
/// focused.
///
/// Contributors: before adding a method to the allowlist or a new ID param,
/// read the "Remote CLI relay authorization" section of the repo-root
/// AGENTS.md. Review bots enforce it via
/// `.github/review-bot-rules/remote-relay-authorization.md`.
public enum RemoteRelayCommandPolicy {
    public enum Verdict: Sendable, Equatable {
        case allow
        case deny(reason: String)
    }

    private enum ScopedKind {
        case workspace
        case surface
        case ambiguous
    }

    // MARK: - ID keys (shared with the app-side alias rewriter)

    public static let workspaceIDKeys: Set<String> = [
        "workspace_id",
        "preferred_workspace_id",
        "selected_workspace_id",
        "before_workspace_id",
        "after_workspace_id",
        "from_workspace_id",
        "to_workspace_id",
    ]

    public static let surfaceIDKeys: Set<String> = [
        "panel_id",
        "surface_id",
        "preferred_panel_id",
        "preferred_surface_id",
        "target_panel_id",
        "target_surface_id",
        "created_panel_id",
        "created_surface_id",
        "before_panel_id",
        "before_surface_id",
        "after_panel_id",
        "after_surface_id",
    ]

    public static let ambiguousIDKeys: Set<String> = [
        "tab_id",
    ]

    public static let workspaceIDArrayKeys: Set<String> = [
        "workspace_ids",
    ]

    public static let surfaceIDArrayKeys: Set<String> = [
        "panel_ids",
        "surface_ids",
    ]

    public static let ambiguousIDArrayKeys: Set<String> = [
        "tab_ids",
        "tab_id_groups",
    ]

    // MARK: - Method allowlist

    /// Exact v2 methods the remote product surface may invoke. Mirrors the
    /// remote CLI command table (`daemon/remote/cmd/cmuxd-remote/commands.go`),
    /// the stamped agent-hook methods, and tmux-compat respawn. Notably
    /// absent: `workspace.create` and `window.create`, which can only mint
    /// local objects the remote has no legitimate way to drive safely.
    private static let allowedMethods: Set<String> = [
        "system.ping",
        "system.capabilities",

        "notification.create",
        "notification.create_for_caller",
        "notification.dismiss",
        "notification.jump_to_unread",
        "notification.mark_read",
        "notification.open",

        "workspace.list",
        "workspace.current",
        "workspace.close",
        "workspace.select",
        "workspace.rename",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.equalize_splits",
        "workspace.move_to_window",

        "window.list",
        "window.current",
        "window.focus",
        "window.close",

        "surface.list",
        "surface.current",
        "surface.read_text",
        "surface.create",
        "surface.split",
        "surface.close",
        "surface.focus",
        "surface.refresh",
        "surface.clear_history",
        "surface.send_text",
        "surface.send_key",
        "surface.resume.set",
        "surface.report_tty",
        "surface.ports_kick",

        "workspace.remote.terminal_session_launching",
        "workspace.remote.terminal_session_connected",
        "workspace.remote.reconnect",

        "pane.list",
        "pane.surfaces",
        "pane.create",
        "pane.break",
        "pane.join",
        "pane.last",
        "pane.resize",
        "pane.swap",
        "pane.focus",

        "agent.resolve_delivery_target",
    ]

    /// `workspace.group.` subcommands stay available remotely except the ones
    /// that mint or destroy local workspaces.
    private static let deniedWorkspaceGroupMethods: Set<String> = [
        "workspace.group.create",
        "workspace.group.new_workspace",
        "workspace.group.delete",
    ]

    /// Methods that create content inside a workspace and therefore must name
    /// an explicit aliased remote target (never the focused local context).
    /// Public so the relay server can learn the IDs these methods return.
    public static let createMethodsRequiringRemoteTarget: Set<String> = [
        "surface.create",
        "surface.split",
        "pane.create",
    ]

    /// Parameter keys that execute a command. Denied on every method: a
    /// relay cannot verify server-side that a start command will re-exec on
    /// the remote host, and the app's plain-SSH respawn path executes
    /// locally, so there is no safe relay-carried command parameter.
    private static let commandParameterKeys: Set<String> = [
        "initial_command",
        "command",
        "tmux_start_command",
        "pane_start_command",
    ]

    // MARK: - Evaluation

    public static func evaluate(
        commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Verdict {
        guard let line = String(data: commandLine, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            line.hasPrefix("{"),
            let requestData = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        else {
            return .deny(reason: "remote relay commands must be v2 JSON-RPC requests")
        }

        guard let method = request["method"] as? String, !method.isEmpty else {
            return .deny(reason: "remote relay command is missing a method")
        }

        if method.hasPrefix("workspace.group.") {
            if deniedWorkspaceGroupMethods.contains(method) {
                return .deny(reason: "method '\(method)' is not permitted through a remote relay")
            }
        } else if method.hasPrefix("browser.") {
            // Browser automation targets surfaces; the scoping pass below
            // constrains it to aliased remote browser surfaces.
        } else if !allowedMethods.contains(method) {
            return .deny(reason: "method '\(method)' is not permitted through a remote relay")
        }

        let params = request["params"] as? [String: Any] ?? [:]

        if let commandKey = firstCommandParameterKey(in: params) {
            return .deny(reason: "parameter '\(commandKey)' is not permitted through a remote relay")
        }

        if let scopingDenial = scopedTargetVerdict(
            in: params,
            key: nil,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        ) {
            return scopingDenial
        }

        if createMethodsRequiringRemoteTarget.contains(method),
           !hasAliasedTarget(
               in: params,
               key: nil,
               workspaceAliases: workspaceAliases,
               surfaceAliases: surfaceAliases
           ) {
            return .deny(reason: "'\(method)' through a remote relay requires an explicit remote workspace or surface target")
        }

        return .allow
    }

    // MARK: - Recursive parameter scans

    private static func firstCommandParameterKey(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() where commandParameterKeys.contains(key) {
                return key
            }
            for (childKey, childValue) in dictionary where !commandParameterKeys.contains(childKey) {
                if let found = firstCommandParameterKey(in: childValue) { return found }
            }
            return nil
        }
        if let array = value as? [Any] {
            for element in array {
                if let found = firstCommandParameterKey(in: element) { return found }
            }
        }
        return nil
    }

    /// Returns a denial when any scoped ID parameter names something outside
    /// the remote session's owned set (alias-map keys ∪ values). Values that
    /// are not UUIDs (including `workspace:3`-style refs, which would index
    /// into local objects) are denied as well: the remote only ever
    /// legitimately speaks in the UUIDs it was issued.
    private static func scopedTargetVerdict(
        in value: Any,
        key: String?,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Verdict? {
        if let dictionary = value as? [String: Any] {
            for (childKey, childValue) in dictionary {
                if let verdict = scopedTargetVerdict(
                    in: childValue,
                    key: childKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases
                ) {
                    return verdict
                }
            }
            return nil
        }

        if let array = value as? [Any] {
            let elementKey = arrayElementKey(for: key)
            for element in array {
                if let verdict = scopedTargetVerdict(
                    in: element,
                    key: elementKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases
                ) {
                    return verdict
                }
            }
            return nil
        }

        guard let key,
              let kind = scopedKind(for: key),
              let raw = value as? String
        else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else {
            return .deny(reason: "'\(key)' must be a remote-issued UUID through a remote relay")
        }
        return isOwned(uuid, kind: kind, workspaceAliases: workspaceAliases, surfaceAliases: surfaceAliases)
            ? nil
            : .deny(reason: "'\(key)' does not name an object owned by this remote session")
    }

    private static func hasAliasedTarget(
        in value: Any,
        key: String?,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (childKey, childValue) in dictionary {
                if hasAliasedTarget(
                    in: childValue,
                    key: childKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases
                ) {
                    return true
                }
            }
            return false
        }

        if let array = value as? [Any] {
            let elementKey = arrayElementKey(for: key)
            for element in array where hasAliasedTarget(
                in: element,
                key: elementKey,
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases
            ) {
                return true
            }
            return false
        }

        guard let key,
              let kind = scopedKind(for: key),
              let raw = value as? String,
              let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return false
        }
        return isOwned(uuid, kind: kind, workspaceAliases: workspaceAliases, surfaceAliases: surfaceAliases)
    }

    /// The remote session's owned objects: alias-map keys (remote-minted
    /// snapshot IDs) ∪ values (live local IDs). Values must count because the
    /// app writes the live local UUIDs into the remote shell's environment,
    /// so a fresh session (no snapshot restore, no distinct remote IDs)
    /// legitimately addresses its own workspace and surfaces by local UUID.
    private static func isOwned(
        _ uuid: UUID,
        kind: ScopedKind,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Bool {
        switch kind {
        case .workspace:
            return workspaceAliases[uuid] != nil || workspaceAliases.values.contains(uuid)
        case .surface:
            return surfaceAliases[uuid] != nil || surfaceAliases.values.contains(uuid)
        case .ambiguous:
            return workspaceAliases[uuid] != nil || workspaceAliases.values.contains(uuid)
                || surfaceAliases[uuid] != nil || surfaceAliases.values.contains(uuid)
        }
    }

    private static func scopedKind(for key: String) -> ScopedKind? {
        if workspaceIDKeys.contains(key) { return .workspace }
        if surfaceIDKeys.contains(key) { return .surface }
        if ambiguousIDKeys.contains(key) { return .ambiguous }
        return nil
    }

    private static func arrayElementKey(for key: String?) -> String? {
        guard let key else { return nil }
        if workspaceIDArrayKeys.contains(key) { return "workspace_id" }
        if surfaceIDArrayKeys.contains(key) { return "surface_id" }
        if ambiguousIDArrayKeys.contains(key) { return "tab_id" }
        if scopedKind(for: key) != nil { return key }
        return nil
    }
}
