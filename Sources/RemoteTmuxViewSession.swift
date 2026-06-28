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
    /// session: the three (controlled, separator-free) ownership options first,
    /// then the free-text `session_name` LAST so a separator inside a name can't
    /// shift fields or drop the row.
    static let listFormat =
        "#{\(optView)}\u{1f}#{\(optOwner)}\u{1f}#{\(optVersion)}\u{1f}#{session_name}"

    /// One parsed `list-sessions` row (from ``listFormat``).
    struct SessionRow: Equatable {
        let name: String
        let isView: Bool       // @cmux_view == "1"
        let owner: String      // @cmux_view_owner ("" if unset)
        let version: Int?      // @cmux_view_version
    }

    static func parseRows(_ output: String) -> [SessionRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            // maxSplits=3 keeps the trailing (free-text) name intact even if it
            // contains the unit separator.
            let f = line.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4 else { return nil }
            return SessionRow(
                name: String(f[3]),
                isView: f[0] == "1",
                owner: String(f[1]),
                version: Int(f[2])
            )
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
        String(owner.unicodeScalars.map { s -> Character in
            if s == "." || s == ":" || CharacterSet.whitespaces.contains(s) { return "-" }
            return Character(s)
        })
    }

    /// A short, stable, collision-resistant hex digest of the raw owner id
    /// (FNV-1a/64 → 16 hex chars), so two distinct owners can never share a view
    /// session name even if their sanitized fragments collide.
    static func ownerHash(_ owner: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in owner.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Single-quote for a control-mode command argument.
    private static func q(_ v: String) -> String { RemoteTmuxHost.shellSingleQuoted(v) }
}
