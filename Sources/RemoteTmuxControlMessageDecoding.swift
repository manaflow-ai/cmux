import Foundation

/// Stateless pure decoders for `tmux -CC` control-mode message payloads.
///
/// These transform untrusted remote-tmux text (a `display-message` `key=value,…`
/// line, a captured stderr string, an optimistic window reorder) into the values
/// ``RemoteTmuxControlConnection`` applies to the mirror. They hold no state and
/// touch no actor isolation, so they are `nonisolated` and safe to call from any
/// context; ``RemoteTmuxControlConnection`` owns an instance and routes its
/// internal call sites through it.
struct RemoteTmuxControlMessageDecoding {
    /// Builds the escape sequence that restores a pane's terminal state onto the
    /// mirror surface, from a `display-message` `key=value,…` line. Sets the scroll
    /// region (DECSTBM), the DEC private modes (wrap/cursor/insert/app-cursor-keys/
    /// keypad), mouse tracking, origin mode, and finally the cursor position.
    ///
    /// The cursor placement is emitted LAST on purpose: setting the scroll region
    /// (DECSTBM) and changing origin mode (DECOM) each move the cursor to the home
    /// position, so any earlier cursor placement would be lost. When origin mode is
    /// on with a restricted region, tmux's absolute cursor row is translated to the
    /// region-relative row the (origin-relative) CUP then expects.
    nonisolated func paneStateSeedSequence(from line: String) -> Data {
        var fields: [String: String] = [:]
        for pair in line.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        let on: (String) -> Bool = { fields[$0] == "1" }
        // Clamp to a plausible terminal-dimension range: the values come from an
        // untrusted remote, and a crafted `Int.min`/`Int.max` would trap the later
        // `+ 1` / `- 1` arithmetic (Swift overflow is a hard crash). Out-of-range or
        // non-numeric values are treated as absent.
        let num: (String) -> Int? = { fields[$0].flatMap { Int($0) }.flatMap { (0...65535).contains($0) ? $0 : nil } }

        // Reset SGR attributes first so the cursor's style pen starts from a known
        // baseline on a surface REUSED across reconnect — a prior alt-screen exit's
        // restoreCursor can otherwise leave a stale style. The captured rows below
        // carry their own SGR; this only affects the pen for subsequent writes.
        var seq = "\u{1b}[m"
        // Scroll region (DECSTBM) — tmux reports 0-based, DECSTBM is 1-based. Only
        // seed a RESTRICTED region: a full-window region (upper 0, lower height-1)
        // is the surface's default already, and pinning it to the capture-time row
        // count would go stale across a later resize (the surface, left at default,
        // tracks resizes on its own). A restricted region is re-asserted by the
        // remote app on its next redraw, so a transiently stale one self-heals.
        let regionUpper = num("scroll_region_upper")
        var restrictedRegion = false
        if let upper = regionUpper, let lower = num("scroll_region_lower"), lower >= upper {
            let isFullWindow = upper == 0 && (num("pane_height").map { lower == $0 - 1 } ?? false)
            if !isFullWindow {
                seq += "\u{1b}[\(upper + 1);\(lower + 1)r"
                restrictedRegion = true
            }
        }
        seq += on("wrap_flag") ? "\u{1b}[?7h" : "\u{1b}[?7l"            // DECAWM
        seq += on("cursor_flag") ? "\u{1b}[?25h" : "\u{1b}[?25l"        // DECTCEM (cursor visible)
        seq += on("insert_flag") ? "\u{1b}[4h" : "\u{1b}[4l"           // IRM
        seq += on("keypad_cursor_flag") ? "\u{1b}[?1h" : "\u{1b}[?1l"   // DECCKM (app cursor keys)
        seq += on("keypad_flag") ? "\u{1b}=" : "\u{1b}>"              // DECKPAM / DECKPNM
        // Mouse: enable the active tracking mode + encoding so clicks/scroll/drag in
        // the mirror reach the remote app (the surface defaults to off). The
        // tmux-flag → xterm DECSET mapping below was verified empirically against
        // tmux 3.6a (set the DECSET in a pane, read the flags back):
        //   ?1000h → mouse_standard_flag,  ?1002h → mouse_button_flag,
        //   ?1003h → mouse_all_flag,  and mouse_any_flag is set for ALL of them.
        // So enable the most aggressive concrete flag that is on, plus the encoding
        // (SGR/1006 preferred over UTF-8/1005). `mouse_any_flag` is deliberately NOT
        // used: it is tmux's aggregate "any mouse mode on" OR-flag, not a concrete
        // level. (NOTE: ghostty's vendored tmux viewer uses a different, one-slot-
        // shifted mapping — do not "align" to it; the above matches real tmux.)
        // Reset all mouse tracking + encoding modes FIRST, then conditionally enable
        // the active one below. Unlike wrap/cursor/insert/origin above (which emit both
        // on/off forms), the mouse enables are one-directional, so on a surface REUSED
        // across reconnect a stale mouse mode would otherwise persist when the pane now
        // has mouse off — leaving clicks/scroll forwarded to an app that no longer wants them.
        seq += "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1005l\u{1b}[?1006l"
        if on("mouse_all_flag") { seq += "\u{1b}[?1003h" }
        else if on("mouse_button_flag") { seq += "\u{1b}[?1002h" }
        else if on("mouse_standard_flag") { seq += "\u{1b}[?1000h" }
        if on("mouse_sgr_flag") { seq += "\u{1b}[?1006h" }
        else if on("mouse_utf8_flag") { seq += "\u{1b}[?1005h" }
        // (Bracketed-paste mode is intentionally not seeded: tmux exposes no
        // reliable pane format for it, and paste fidelity is handled by tmux's own
        // `paste-buffer -p` in ``pastePane(paneId:text:)``.)
        // Origin mode (DECOM) before the cursor — changing it homes the cursor.
        let originOn = on("origin_flag")
        seq += originOn ? "\u{1b}[?6h" : "\u{1b}[?6l"
        // Cursor LAST. tmux reports an absolute row; with origin mode on and a
        // restricted region the CUP is interpreted region-relative, so subtract the
        // region top.
        if let cx = num("cursor_x"), let cy = num("cursor_y") {
            let row = (originOn && restrictedRegion) ? max(0, cy - (regionUpper ?? 0)) : cy
            seq += "\u{1b}[\(row + 1);\(cx + 1)H"
        }
        return Data(seq.utf8)
    }

    /// Returns `order` with the windows in `reordered` rearranged into
    /// `reordered`'s sequence, leaving windows not in that set in their positions.
    nonisolated func windowOrder(_ order: [Int], applyingReorder reordered: [Int]) -> [Int] {
        let set = Set(reordered)
        var iterator = reordered.makeIterator()
        return order.map { set.contains($0) ? (iterator.next() ?? $0) : $0 }
    }

    /// Whether captured ssh/tmux stderr indicates the session/server is genuinely
    /// gone (reconnect should stop and end) vs a transient transport failure (host
    /// unreachable / connection refused — keep retrying).
    nonisolated func stderrIndicatesSessionGone(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return controlOutputIndicatesSessionGone(stderr)
            || lowered.contains("can't find session")
            || lowered.contains("can\u{2019}t find session")
            || lowered.contains("no server running")
            || lowered.contains("no current session")
            || lowered.contains("session not found")
            || lowered.contains("lost server")
    }

    /// Whether unframed output from the forced SSH PTY is an exact tmux
    /// attach failure. Remote stderr shares stdout under `ssh -tt`, so these
    /// lines arrive as unparsed control-stream output rather than local stderr.
    nonisolated func controlOutputIndicatesSessionGone(_ output: String) -> Bool {
        output.lowercased().split(whereSeparator: \.isNewline).contains { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            return line == "no sessions"
                || line.hasPrefix("no server running on ")
                || line.hasPrefix("can't find session:")
                || line.hasPrefix("can\u{2019}t find session:")
                || line == "no current session"
                || line.hasPrefix("session not found")
                || line == "lost server"
        }
    }
}
