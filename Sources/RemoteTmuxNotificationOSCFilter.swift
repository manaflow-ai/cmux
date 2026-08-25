import Foundation

/// Intercepts OSC desktop-notification escapes in a mirrored pane's output
/// stream (issue #833).
///
/// A remote process inside an ssh-tmux mirror emits notifications with the
/// xterm/urxvt OSC sequences:
/// - `ESC ] 777;notify;<title>;<body> BEL|ST` (rxvt-unicode / wezterm style)
/// - `ESC ] 9;<body> BEL|ST` (iTerm2 growl style; no title)
///
/// `%output` is the raw pty copy, so tmux forwards these bytes verbatim to the
/// mirror. The mirror's Ghostty surface would parse them, but its
/// `desktop_notification` callback attributes by the surface's local process
/// TTY — which a manual-mirror surface does not have — and mirror workspaces
/// are excluded from agent TTY delivery (`AgentDeliveryTargetResolution`). So
/// the mirror layer intercepts the sequence here, strips it from the stream,
/// and reports `(title, body)` so the session mirror can attribute the
/// notification to the pane's surface + workspace itself.
///
/// Any other OSC sequence (titles, hyperlinks, clipboard, non-`notify`
/// OSC 777 subcommands) passes through byte-identical.
///
/// Stateful across calls: a `%output` chunk can split the sequence at any
/// byte. While a sequence still *might* be a notification its bytes are
/// buffered; the moment the payload diverges from both notification prefixes
/// the buffer is flushed verbatim and the rest of the sequence streams
/// through unbuffered. An unfinished candidate that exceeds
/// ``maxBufferedBytes`` is flushed verbatim too, so a hostile or corrupt
/// stream can never pin memory or swallow output.
struct RemoteTmuxNotificationOSCFilter {
    private enum State {
        case text        // normal passthrough
        case esc         // saw ESC, holding it until we know if it's `ESC ]`
        case collect     // inside an OSC that may still be a notification; buffering
        case collectEsc  // in collect, saw ESC; maybe the `ESC \` terminator
        case passOsc     // inside a non-notification OSC; streaming through
        case passOscEsc  // in passOsc, saw ESC; maybe the `ESC \` terminator
    }

    /// Ceiling on bytes buffered for an unfinished candidate sequence. An
    /// overflowing sequence is passed through verbatim instead of stripped.
    static let maxBufferedBytes = 4096

    private static let notifyPrefix = Array("777;notify;".utf8)
    private static let osc9Prefix = Array("9;".utf8)

    private var state: State = .text
    /// Original bytes of the candidate sequence (`ESC ]` + payload so far),
    /// replayed verbatim when the sequence turns out not to be a notification.
    private var raw: [UInt8] = []
    /// Payload bytes only (after `ESC ]`), matched against the prefixes and
    /// decoded into `(title, body)` on a hit.
    private var payload: [UInt8] = []

    /// Creates a filter with no buffered escape-sequence state.
    init() {}

    /// Returns `data` with any complete notification sequences removed,
    /// invoking `onNotification(title, body)` once per hit in stream order.
    /// OSC 9 hits report an empty title.
    mutating func filter(
        _ data: Data,
        onNotification: (_ title: String, _ body: String) -> Void
    ) -> Data {
        // Hot path: not mid-sequence and no ESC in the chunk — nothing to do.
        if state == .text, !data.contains(0x1b) { return data }
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1b {
                    state = .esc            // hold the ESC; emit it only if it isn't `ESC ]`
                } else {
                    out.append(byte)
                }
            case .esc:
                if byte == UInt8(ascii: "]") {
                    raw = [0x1b, byte]
                    payload.removeAll(keepingCapacity: true)
                    state = .collect
                } else if byte == 0x1b {
                    out.append(0x1b)        // emit the held ESC, keep holding the new one
                } else {
                    out.append(0x1b)
                    out.append(byte)
                    state = .text
                }
            case .collect:
                if byte == 0x07 {           // BEL terminator
                    finishCandidate(terminator: [0x07], into: &out, onNotification)
                } else if byte == 0x1b {
                    state = .collectEsc
                } else {
                    raw.append(byte)
                    payload.append(byte)
                    reclassifyCandidate(into: &out)
                }
            case .collectEsc:
                if byte == 0x5c {           // `ESC \` (ST) terminator
                    finishCandidate(terminator: [0x1b, 0x5c], into: &out, onNotification)
                } else {
                    // An OSC payload cannot legally contain a bare ESC; treat the
                    // sequence as malformed and pass everything through verbatim.
                    out.append(contentsOf: raw)
                    out.append(0x1b)
                    raw.removeAll(keepingCapacity: true)
                    payload.removeAll(keepingCapacity: true)
                    if byte == 0x1b {
                        state = .esc        // the new ESC may start a fresh sequence
                    } else {
                        out.append(byte)
                        state = .text
                    }
                }
            case .passOsc:
                if byte == 0x07 {
                    out.append(byte)
                    state = .text
                } else if byte == 0x1b {
                    state = .passOscEsc
                } else {
                    out.append(byte)
                }
            case .passOscEsc:
                if byte == 0x5c {
                    out.append(0x1b)
                    out.append(0x5c)
                    state = .text
                } else if byte == 0x1b {
                    out.append(0x1b)        // emit the held ESC, keep holding the new one
                } else {
                    out.append(0x1b)
                    out.append(byte)
                    state = .passOsc
                }
            }
        }
        return Data(out)
    }

    /// While collecting, checks the payload against both notification prefixes
    /// and the buffer ceiling; a sequence that can no longer be a notification
    /// (or grew too large unfinished) is flushed verbatim and the remainder
    /// streams through as a plain OSC.
    private mutating func reclassifyCandidate(into out: inout [UInt8]) {
        if raw.count <= Self.maxBufferedBytes,
           Self.couldMatch(payload, prefix: Self.notifyPrefix)
            || Self.couldMatch(payload, prefix: Self.osc9Prefix) {
            return
        }
        out.append(contentsOf: raw)
        raw.removeAll(keepingCapacity: true)
        payload.removeAll(keepingCapacity: true)
        state = .passOsc
    }

    /// Whether `payload` is still compatible with `prefix` (either side is a
    /// prefix of the other).
    private static func couldMatch(_ payload: [UInt8], prefix: [UInt8]) -> Bool {
        payload.count >= prefix.count
            ? payload.starts(with: prefix)
            : prefix.starts(with: payload)
    }

    /// A candidate sequence reached its terminator: strip + report a
    /// notification hit, or replay the original bytes for anything else
    /// (including a too-short candidate like `ESC ] 9 BEL`).
    private mutating func finishCandidate(
        terminator: [UInt8],
        into out: inout [UInt8],
        _ onNotification: (_ title: String, _ body: String) -> Void
    ) {
        defer {
            raw.removeAll(keepingCapacity: true)
            payload.removeAll(keepingCapacity: true)
            state = .text
        }
        if payload.starts(with: Self.notifyPrefix) {
            let rest = payload.dropFirst(Self.notifyPrefix.count)
            if let separator = rest.firstIndex(of: UInt8(ascii: ";")) {
                onNotification(
                    Self.decode(rest[..<separator]),
                    Self.decode(rest[rest.index(after: separator)...])
                )
            } else {
                // `777;notify;<title>` without a body separator: title only.
                onNotification(Self.decode(rest), "")
            }
        } else if payload.starts(with: Self.osc9Prefix) {
            onNotification("", Self.decode(payload.dropFirst(Self.osc9Prefix.count)))
        } else {
            out.append(contentsOf: raw)
            out.append(contentsOf: terminator)
        }
    }

    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
