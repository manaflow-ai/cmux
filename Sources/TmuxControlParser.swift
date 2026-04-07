import Foundation

// MARK: - Future tmux protocol features (not yet implemented)
//
// TODO(tmux-phase3): %pause %<paneId> / %continue — pause-mode backpressure (tmux ≥3.2).
//   Requires per-pane buffer monitoring and `refresh-client -f pause-after=<ms>`.
//
// TODO(tmux-phase3): %subscription-changed <id> ... — subscription-based option monitoring
//   (tmux ≥3.2). Replaces polling for format/option values.
//
// TODO(tmux-phase3): Pane history retrieval — capture-pane -p -S - to populate
//   scrollback buffer on attach so users see prior output.
//
// TODO(tmux-phase3): Copy-mode exit on attach — send `copy-mode -q` if pane starts
//   in copy mode (e.g. tmux.conf errors). Check pane_in_mode format flag.
//
// TODO(tmux-phase3): Per-window resize via `refresh-client -C` (tmux ≥3.4) so each
//   window can have its own terminal size rather than a single global size.
//
// TODO(tmux-phase3): Focus events — check/set `focus-events` tmux option so apps
//   that need focus state (vim, emacs) behave correctly in tmux panes.
//
// TODO(tmux-phase3): Double-attach detection — check @cmux_id session variable to
//   detect re-entry from same or different cmux instance before attaching.
//
// TODO(tmux-phase3): Session variable persistence — save/restore remoteTmuxSessionName
//   via `@cmux_<workspaceId>` session variable so reattach works after app restart
//   without needing to re-show the session picker.

// MARK: - Layout tree types

/// Geometry and identity of a leaf tmux pane in a layout string.
struct TmuxPaneGeometry: Equatable {
    let paneId: String   // e.g. "%3"
    let width: Int
    let height: Int
    let x: Int
    let y: Int
}

/// A node in the tmux layout tree. Leaf nodes represent panes; inner nodes
/// represent horizontal (`{...}`) or vertical (`[...]`) splits.
indirect enum TmuxLayoutNode: Equatable {
    /// A leaf pane with its geometry.
    case pane(TmuxPaneGeometry)
    /// A horizontal split (`{...}`) — children are arranged side-by-side.
    case horizontal([TmuxLayoutNode], width: Int, height: Int, x: Int, y: Int)
    /// A vertical split (`[...]`) — children are stacked top-to-bottom.
    case vertical([TmuxLayoutNode], width: Int, height: Int, x: Int, y: Int)

    /// All pane IDs reachable from this node, in tree traversal order.
    var allPaneIds: [String] {
        switch self {
        case .pane(let g):
            return [g.paneId]
        case .horizontal(let children, _, _, _, _),
             .vertical(let children, _, _, _, _):
            return children.flatMap(\.allPaneIds)
        }
    }

    static func == (lhs: TmuxLayoutNode, rhs: TmuxLayoutNode) -> Bool {
        switch (lhs, rhs) {
        case (.pane(let a), .pane(let b)):
            return a == b
        case let (.horizontal(ac, aw, ah, ax, ay), .horizontal(bc, bw, bh, bx, by)),
             let (.vertical(ac, aw, ah, ax, ay), .vertical(bc, bw, bh, bx, by)):
            return ac == bc && aw == bw && ah == bh && ax == bx && ay == by
        default:
            return false
        }
    }
}

/// A fully parsed tmux window layout.
struct TmuxLayout: Equatable {
    let windowId: String
    /// Raw window-flags token from `%layout-change` (e.g. `"*Z"`, `""`).
    let windowFlags: String
    let root: TmuxLayoutNode

    /// True when the window flags include "Z" (zoomed pane active).
    var isZoomed: Bool { windowFlags.contains("Z") }

    /// All pane IDs in the layout, in tree traversal order.
    var allPaneIds: [String] { root.allPaneIds }
}

// MARK: - Events

/// An event emitted by tmux control mode (`tmux -CC`).
enum TmuxControlEvent {
    /// Layout changed in a window. The full layout tree is included.
    case layoutChange(layout: TmuxLayout)
    /// A new window was added to the session.
    case windowAdd(window: String)
    /// A window was closed.
    case windowClose(window: String)
    /// The session was renamed. Format: `%session-renamed $<id> <newName>`.
    case sessionRenamed(sessionId: String, newName: String)
    /// One or more sessions were added, removed, or changed.
    case sessionsChanged
    /// A window was renamed.
    case windowRenamed(window: String, newName: String)
    /// The active window in a session changed.
    case sessionWindowChanged(sessionId: String, window: String)
    /// The active pane in a window changed.
    case windowPaneChanged(window: String, paneId: String)
    /// A pane's mode changed (e.g. entered or exited copy mode). tmux ≥2.5.
    case paneModeChanged(paneId: String, mode: String)
    /// A paste buffer was added or modified.
    case pasteBufferChanged
    /// A client switched to a different session. tmux ≥3.6.
    case clientSessionChanged
    /// tmux control mode is exiting.
    case exit
}

// MARK: - Parser

/// Parses lines from `tmux -CC` control mode stdout.
struct TmuxControlParser {
    private init() {}

    /// Parse a single raw line. Returns `nil` for lines that are not known events
    /// (e.g. `%begin`/`%end` wrappers, escape sequences, blank lines).
    static func parseLine(_ raw: String) -> TmuxControlEvent? {
        // Strip leading/trailing whitespace and carriage returns.
        var line = raw
        while line.hasSuffix("\r") || line.hasSuffix("\n") {
            line.removeLast()
        }
        line = line.trimmingCharacters(in: .whitespaces)

        // Skip DCS escape sequences and anything without the % prefix.
        guard line.hasPrefix("%") else { return nil }

        // Split on the first two spaces only so the layout string (which may
        // contain commas but not spaces) is preserved intact.
        let tokens = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        switch tokens[0] {
        case "%layout-change":
            // Format: %layout-change @<windowId> <layoutStr> [<visibleLayout>] [<windowFlags>]
            // We split with maxSplits:2 above so tokens[2] may contain multiple space-separated
            // tokens for visibleLayout and windowFlags. Extract them lazily.
            guard tokens.count >= 3 else { return nil }
            let rest = tokens[2].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            let layoutStr = rest[0]
            // windowFlags is the 3rd token if present (e.g. "Z" for zoomed, "*" for current).
            let windowFlags = rest.count >= 3 ? rest[2] : ""
            guard let layout = parseLayoutTree(windowId: tokens[1], flags: windowFlags,
                                               layoutString: layoutStr) else {
                return nil
            }
            return .layoutChange(layout: layout)

        case "%window-add":
            guard tokens.count >= 2 else { return nil }
            return .windowAdd(window: tokens[1])

        case "%window-close":
            guard tokens.count >= 2 else { return nil }
            return .windowClose(window: tokens[1])

        case "%session-renamed":
            // Format: %session-renamed $<sessionId> <newName>
            guard tokens.count >= 3 else { return nil }
            return .sessionRenamed(sessionId: tokens[1], newName: tokens[2])

        case "%sessions-changed":
            return .sessionsChanged

        case "%window-renamed":
            // Format: %window-renamed @<windowId> <newName>
            guard tokens.count >= 3 else { return nil }
            return .windowRenamed(window: tokens[1], newName: tokens[2])

        case "%session-window-changed":
            // Format: %session-window-changed $<sessionId> @<windowId>
            guard tokens.count >= 3 else { return nil }
            return .sessionWindowChanged(sessionId: tokens[1], window: tokens[2])

        case "%window-pane-changed":
            // Format: %window-pane-changed @<windowId> %<paneId>
            guard tokens.count >= 3 else { return nil }
            return .windowPaneChanged(window: tokens[1], paneId: tokens[2])

        case "%pane-mode-changed":
            // Format: %pane-mode-changed %<paneId> <mode>   (tmux ≥2.5)
            guard tokens.count >= 2 else { return nil }
            let mode = tokens.count >= 3 ? tokens[2] : ""
            return .paneModeChanged(paneId: tokens[1], mode: mode)

        case "%paste-buffer-changed":
            return .pasteBufferChanged

        case "%client-session-changed":
            return .clientSessionChanged

        case "%exit":
            return .exit

        default:
            return nil
        }
    }

    // MARK: - Layout tree parser

    /// Parse a tmux layout string into a `TmuxLayout` tree.
    static func parseLayoutTree(windowId: String, flags: String, layoutString: String) -> TmuxLayout? {
        var idx = layoutString.startIndex
        skipChecksumIfPresent(layoutString, idx: &idx)
        guard let root = parseNode(layoutString, idx: &idx) else { return nil }
        return TmuxLayout(windowId: windowId, windowFlags: flags, root: root)
    }

    /// Return all pane IDs from a layout string, sorted numerically.
    ///
    /// This is a convenience wrapper around `parseLayoutTree` for standalone use
    /// (e.g. unit tests and callers that only need the ID list).
    static func extractPaneIds(from layoutStr: String) -> [String] {
        guard let layout = parseLayoutTree(windowId: "", flags: "", layoutString: layoutStr) else {
            return []
        }
        return layout.allPaneIds.sorted { a, b in
            let na = Int(a.dropFirst()) ?? 0
            let nb = Int(b.dropFirst()) ?? 0
            return na < nb
        }
    }

    // MARK: - Private recursive tree parser

    /// Parse one layout node starting at `idx`. Advances `idx` past the node.
    ///
    /// Grammar (after optional checksum prefix):
    /// ```
    /// node = WxH,X,Y,ID              (leaf pane)
    ///      | WxH,X,Y{node,node,...}  (horizontal split)
    ///      | WxH,X,Y[node,node,...]  (vertical split)
    /// ```
    private static func parseNode(_ s: String, idx: inout String.Index) -> TmuxLayoutNode? {
        guard let (w, h, x, y) = readGeometry(s, idx: &idx),
              idx < s.endIndex else { return nil }

        switch s[idx] {
        case ",":
            // Leaf pane: next token after "," is the numeric pane ID.
            s.formIndex(after: &idx)
            let n = readDigits(s, idx: &idx)
            guard !n.isEmpty else { return nil }
            return .pane(TmuxPaneGeometry(paneId: "%" + n, width: w, height: h, x: x, y: y))

        case "{":
            // Horizontal split.
            s.formIndex(after: &idx)
            var children: [TmuxLayoutNode] = []
            while idx < s.endIndex && s[idx] != "}" {
                if let child = parseNode(s, idx: &idx) { children.append(child) }
                if idx < s.endIndex && s[idx] == "," { s.formIndex(after: &idx) }
            }
            if idx < s.endIndex { s.formIndex(after: &idx) } // consume "}"
            return .horizontal(children, width: w, height: h, x: x, y: y)

        case "[":
            // Vertical split.
            s.formIndex(after: &idx)
            var children: [TmuxLayoutNode] = []
            while idx < s.endIndex && s[idx] != "]" {
                if let child = parseNode(s, idx: &idx) { children.append(child) }
                if idx < s.endIndex && s[idx] == "," { s.formIndex(after: &idx) }
            }
            if idx < s.endIndex { s.formIndex(after: &idx) } // consume "]"
            return .vertical(children, width: w, height: h, x: x, y: y)

        default:
            return nil
        }
    }

    /// Read `WxH,X,Y` geometry and return `(width, height, x, y)`, advancing `idx`.
    private static func readGeometry(_ s: String, idx: inout String.Index) -> (Int, Int, Int, Int)? {
        guard let w = readInt(s, idx: &idx),
              idx < s.endIndex, s[idx] == "x" else { return nil }
        s.formIndex(after: &idx)
        guard let h = readInt(s, idx: &idx),
              let x = readCommaInt(s, idx: &idx),
              let y = readCommaInt(s, idx: &idx) else { return nil }
        return (w, h, x, y)
    }

    /// Read `,<digits>` only when the character after `,` is a decimal digit.
    /// This prevents accidentally consuming the `,` child separator inside `{...}`.
    private static func readCommaInt(_ s: String, idx: inout String.Index) -> Int? {
        guard idx < s.endIndex, s[idx] == "," else { return nil }
        let peek = s.index(after: idx)
        guard peek < s.endIndex, s[peek].isNumber else { return nil }
        s.formIndex(after: &idx) // skip ","
        return readInt(s, idx: &idx)
    }

    private static func readInt(_ s: String, idx: inout String.Index) -> Int? {
        let d = readDigits(s, idx: &idx)
        return d.isEmpty ? nil : Int(d)
    }

    private static func readDigits(_ s: String, idx: inout String.Index) -> String {
        var result = ""
        while idx < s.endIndex && s[idx].isNumber {
            result.append(s[idx])
            s.formIndex(after: &idx)
        }
        return result
    }

    // MARK: - Checksum prefix

    /// Skip the optional `<hex>,` checksum prefix emitted by tmux control mode.
    ///
    /// A checksum is a run of hex digits followed by a comma and then a decimal
    /// digit (start of the geometry width). Peek ahead to confirm before skipping.
    private static func skipChecksumIfPresent(_ s: String, idx: inout String.Index) {
        var probe = idx
        while probe < s.endIndex && s[probe].isHexDigit { s.formIndex(after: &probe) }
        guard probe > idx,
              probe < s.endIndex,
              s[probe] == ",",
              s.index(after: probe) < s.endIndex,
              s[s.index(after: probe)].isNumber
        else { return }
        s.formIndex(after: &probe) // skip ","
        idx = probe
    }
}
