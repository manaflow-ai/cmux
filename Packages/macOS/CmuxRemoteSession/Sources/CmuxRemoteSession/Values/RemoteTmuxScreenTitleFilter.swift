public import Foundation

/// Strips the GNU screen / tmux window-title escape (`ESC k <title> ESC \`) from a
/// mirrored pane's output stream.
///
/// A remote shell running *inside* tmux sees `TERM=screen*`/`tmux*`, so its prompt
/// (e.g. oh-my-zsh) sets the title with the screen sequence `\ek<cmd>\e\\` instead of
/// the xterm OSC. `%output` is the raw pty copy, so tmux forwards the `ESC k` bytes
/// verbatim and only interprets them for its OWN screen (window name) — its rendered
/// pane (`capture-pane`) has the title stripped. cmux's mirror surface is an
/// xterm-style emulator that doesn't recognize `ESC k`, so it would instead print the
/// title text onto the screen — e.g. `echo "ej"\r\n\ekecho\e\\ej` renders as `echoej`.
/// To match what the remote tmux actually shows, the mirror interprets/strips the
/// sequence here (the tab name already tracks tmux's `window_name`).
///
/// Stateful across calls: a `%output` chunk can split the sequence at any byte. Like
/// tmux/screen, `ESC k` is terminated ONLY by ST (`ESC \`), so an unterminated title
/// consumes until ST — matching tmux's own screen exactly (verified empirically by
/// diffing cmux's render against `capture-pane`).
public struct RemoteTmuxScreenTitleFilter {
    private enum State {
        case text        // normal passthrough
        case esc         // saw ESC, holding it until we know if it's `ESC k`
        case title       // inside `ESC k …`, dropping the title bytes
        case titleEsc    // inside the title, saw ESC — maybe the `ESC \` terminator
    }

    private var state: State = .text

    public init() {}

    /// Returns `data` with any `ESC k … ESC \` title sequences removed.
    public mutating func filter(_ data: Data) -> Data {
        // Hot path: routeOutput calls this for every %output chunk. When we're not
        // mid-sequence and the chunk has no ESC, there is nothing to strip — return it
        // unchanged and skip the per-byte copy + allocation.
        if state == .text, !data.contains(0x1b) { return data }
        // Build into a `[UInt8]` buffer (cheaper than per-byte `Data.append`) and wrap
        // it once at the end.
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1b {
                    state = .esc           // hold the ESC; emit it only if it isn't `ESC k`
                } else {
                    out.append(byte)
                }
            case .esc:
                if byte == UInt8(ascii: "k") {
                    state = .title         // `ESC k` → start of title; drop both bytes
                } else {
                    out.append(0x1b)       // not a title: emit the held ESC …
                    if byte == 0x1b {
                        // another ESC: keep holding it (stay in .esc)
                    } else {
                        out.append(byte)   // … followed by this byte
                        state = .text
                    }
                }
            case .title:
                // tmux/screen terminate `ESC k` ONLY on ST (`ESC \`), never on BEL —
                // so a BEL is part of the title and the title runs until ST (matching
                // what the remote tmux renders). Drop everything until then.
                if byte == 0x1b {
                    state = .titleEsc      // maybe the `ESC \` terminator
                }
                // otherwise (incl. BEL): title text — drop it
            case .titleEsc:
                if byte == 0x5c {
                    state = .text          // `ESC \` (ST) terminates the title
                } else if byte == 0x1b {
                    state = .titleEsc      // consecutive ESC — keep waiting
                } else {
                    state = .title         // ESC + other byte: still inside the title
                }
            }
        }
        return Data(out)
    }
}
