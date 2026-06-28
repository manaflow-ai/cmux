import Foundation

/// Identity and ownership for the hidden aggregate **view** session used by the
/// remote-tmux linked-view transport (`remoteTmux.linkedView` beta).
///
/// The view session is cmux-created remote state: one per (host, cmux owner). The
/// single `tmux -CC` control client attaches to it and every mirrored window is
/// `link-window`ed in. Because it is real, visible remote state, it must be:
/// - **uniquely named** so two cmux owners (or a re-launch) never collide,
/// - **tagged** with tmux user options so discovery can tell a view from a real
///   workspace session and tell *our* view from one owned by another cmux,
/// - **reattachable** by the same owner across reconnect/relaunch,
/// - **safe to garbage-collect** when stale, while *never* touching a session
///   that is not a cmux view or is owned by someone else.
///
/// Pure value type: builds names, the tmux option-set commands, and the
/// classification predicates. No tmux/SSH here so the policy is unit-testable.
struct RemoteTmuxViewSession: Equatable {
    /// Stable per-cmux-install owner id (e.g. a UUID persisted in defaults). Lets
    /// us reattach our own view and avoid other cmux installs' views.
    let ownerId: String

    /// Session name format version, so a future incompatible view layout can be
    /// recognized and recreated rather than reused.
    static let formatVersion = 1

    /// tmux user-option keys stamped on the view session (read via
    /// `#{@cmux_view}` etc.). User options must start with `@`.
    static let optView = "@cmux_view"
    static let optOwner = "@cmux_view_owner"
    static let optVersion = "@cmux_view_version"

    /// Prefix all view sessions share, for a cheap first-pass filter and so a
    /// human running `tmux ls` can tell what these are.
    static let namePrefix = "cmux-view-"

    /// The deterministic view session name for this owner.
    ///
    /// tmux session names disallow `.`, `:` and whitespace, so the owner id is
    /// mapped to a safe token. The mapping is **collision-resistant**: distinct
    /// owner ids never produce the same session name (a naive char-replace would
    /// collapse `a.b` and `a:b` to the same name and let two installs fight over
    /// one view). We append a short FNV-1a/64 hash of the *raw* owner id so the
    /// readable part stays human-friendly while uniqueness is preserved.
    var sessionName: String {
        Self.namePrefix + Self.sanitizeOwner(ownerId) + "-" + Self.ownerHash(ownerId)
    }

    /// Raw `tmux` argument vectors (NOT shell-quoted — the one-shot transport
    /// quotes each token) that create the view detached at an explicit size and
    /// stamp the ownership options. Run as sequential pre-attach one-shots, before
    /// any `-CC` client holds the host's single session. Explicit `-x/-y` avoids an
    /// 80x24 placeholder flash before the first resize.
    func createArgvs(cols: Int, rows: Int) -> [[String]] {
        let n = sessionName
        return [
            ["new-session", "-d", "-s", n, "-x", String(cols), "-y", String(rows)],
            ["set-option", "-t", n, Self.optView, "1"],
            ["set-option", "-t", n, Self.optOwner, ownerId],
            ["set-option", "-t", n, Self.optVersion, String(Self.formatVersion)],
            // The single shared `-CC` client can't size each linked window via
            // `refresh-client -C`; `window-size manual` lets the coordinator size
            // every window explicitly with `resize-window -t @id`.
            ["set-option", "-t", n, "window-size", "manual"],
        ]
    }

    /// Format string for `list-sessions -F`. Uses the printable `:` delimiter (the
    /// same one ``RemoteTmuxSessionListParser`` uses) — NOT a control byte: when the
    /// remote tmux client is not flagged UTF-8 (common on non-interactive SSH to a
    /// non-UTF-8-locale host), tmux runs `-F` output through `utf8_sanitize()` which
    /// rewrites every non-printable byte to `_`, which would collapse the fields and
    /// drop every row. The controlled fields (`@cmux_view` = "1"/"" , owner =
    /// colon-free id, version = int) come first; the free-text `session_name` is
    /// LAST and is rejoined from the remainder, so a `:` in a name (tmux already
    /// rewrites those to `_`) can't shift fields.
    static let listFormat =
        "#{\(optView)}:#{\(optOwner)}:#{\(optVersion)}:#{session_name}"

    /// One parsed `list-sessions` row (from ``listFormat``).
    struct SessionRow: Equatable {
        let name: String
        let isView: Bool       // @cmux_view == "1"
        let owner: String      // @cmux_view_owner ("" if unset)
        let version: Int?      // @cmux_view_version
    }

    static func parseRows(_ output: String) -> [SessionRow] {
        RemoteTmuxSessionListParser.splitRows(output, fieldCount: 4).map { f in
            SessionRow(name: f[3], isView: f[0] == "1", owner: f[1], version: Int(f[2]))
        }
    }

    // MARK: - Classification (the safety surface)

    /// Any session that is one of cmux's hidden view sessions — tagged with the
    /// `@cmux_view` option AND carrying the reserved name prefix. Both are required
    /// so a real user session that merely inherited/copied the option (tmux user
    /// options can be set on anything) is never mistaken for a view. The set of
    /// these is what the workspace model excludes, so a *foreign* owner's view is
    /// never surfaced as a workspace nor linked.
    static func isAnyView(_ row: SessionRow) -> Bool {
        row.isView && row.name.hasPrefix(namePrefix)
    }

    /// This row is *our* view: a cmux view (tagged + prefixed), owned by us, the
    /// current format, with the exact name we use. Only a match is reattached.
    func isOwnView(_ row: SessionRow) -> Bool {
        Self.isAnyView(row) && row.owner == ownerId && row.version == Self.formatVersion
            && row.name == sessionName
    }

    /// A stale view owned by *us* that we may garbage-collect: a cmux view
    /// (tagged + prefixed), our owner, but a different name/version than the one we
    /// use now (e.g. an old format from a previous build). The prefix requirement
    /// means a non-view session can never be collected even if its options were
    /// copied; the owner requirement means another install's view is never ours.
    func isOwnStaleView(_ row: SessionRow) -> Bool {
        Self.isAnyView(row) && row.owner == ownerId && !isOwnView(row)
    }

    /// A view owned by a *different* cmux install. Must never be touched.
    static func isForeignView(_ row: SessionRow, ownerId: String) -> Bool {
        isAnyView(row) && !row.owner.isEmpty && row.owner != ownerId
    }

    // MARK: - Helpers

    /// tmux session names cannot contain `.`, `:`, or whitespace; map them out so
    /// an arbitrary owner id yields a valid, readable session-name fragment. Lossy
    /// on purpose (readability); uniqueness is restored by ``ownerHash(_:)``.
    static func sanitizeOwner(_ owner: String) -> String {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return String(owner.unicodeScalars.map { s -> Character in
            if s == "." || s == ":" || forbidden.contains(s) { return "-" }
            return Character(s)
        })
    }

    /// A short, stable, collision-resistant hex digest of the raw owner id
    /// (FNV-1a/64 → 16 hex chars), so two distinct owners can never share a view
    /// session name even if their sanitized fragments collide. Reuses the shared
    /// digest helper so the FNV algorithm isn't duplicated.
    static func ownerHash(_ owner: String) -> String {
        RemoteTmuxHost.fnv1a64Hex(owner)
    }
}
