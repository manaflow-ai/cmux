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

    /// The deterministic view session name for this owner. Sanitized to tmux-safe
    /// characters (tmux session names disallow `.`, `:` and whitespace).
    var sessionName: String {
        Self.namePrefix + Self.sanitizeOwner(ownerId)
    }

    /// tmux commands (control-mode safe, one per line) that create the view
    /// detached at an explicit size and stamp ownership options. Creating with an
    /// explicit `-x/-y` avoids an 80x24 placeholder flash before the first resize.
    ///
    /// `new-session -d -s <name>` is idempotent only if guarded; callers use
    /// ``hasSessionGuardedCreateCommands(cols:rows:)`` which create-or-noops.
    func createCommands(cols: Int, rows: Int) -> [String] {
        let n = sessionName
        return [
            "new-session -d -s \(Self.q(n)) -x \(cols) -y \(rows)",
            "set-option -t \(Self.q(n)) \(Self.optView) 1",
            "set-option -t \(Self.q(n)) \(Self.optOwner) \(Self.q(ownerId))",
            "set-option -t \(Self.q(n)) \(Self.optVersion) \(Self.formatVersion)",
        ]
    }

    /// Format string for `list-sessions -F` that surfaces enough to classify each
    /// session: name + the three ownership options.
    static let listFormat =
        "#{session_name}\u{1f}#{\(optView)}\u{1f}#{\(optOwner)}\u{1f}#{\(optVersion)}"

    /// One parsed `list-sessions` row (from ``listFormat``).
    struct SessionRow: Equatable {
        let name: String
        let isView: Bool       // @cmux_view == "1"
        let owner: String      // @cmux_view_owner ("" if unset)
        let version: Int?      // @cmux_view_version
    }

    static func parseRows(_ output: String) -> [SessionRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 4 else { return nil }
            return SessionRow(
                name: f[0],
                isView: f[1] == "1",
                owner: f[2],
                version: Int(f[3])
            )
        }
    }

    // MARK: - Classification (the safety surface)

    /// This row is *our* view: tagged as a view, owned by us, current format.
    /// Only a row matching this is ever reattached/reused.
    func isOwnView(_ row: SessionRow) -> Bool {
        row.isView && row.owner == ownerId && row.version == Self.formatVersion
            && row.name == sessionName
    }

    /// A stale view owned by *us* that we may garbage-collect: tagged as a view,
    /// our owner, but a different name/version than the one we use now (e.g. an
    /// old format left by a previous build). Never includes other owners' views.
    func isOwnStaleView(_ row: SessionRow) -> Bool {
        row.isView && row.owner == ownerId && !isOwnView(row)
    }

    /// A view owned by a *different* cmux install. Must never be touched.
    static func isForeignView(_ row: SessionRow, ownerId: String) -> Bool {
        row.isView && !row.owner.isEmpty && row.owner != ownerId
    }

    // MARK: - Helpers

    /// tmux session names cannot contain `.`, `:`, or whitespace; map them out so
    /// an arbitrary owner id yields a valid, stable session name.
    static func sanitizeOwner(_ owner: String) -> String {
        String(owner.unicodeScalars.map { s -> Character in
            if s == "." || s == ":" || CharacterSet.whitespaces.contains(s) { return "-" }
            return Character(s)
        })
    }

    /// Single-quote for a control-mode command argument.
    private static func q(_ v: String) -> String { RemoteTmuxHost.shellSingleQuoted(v) }
}
