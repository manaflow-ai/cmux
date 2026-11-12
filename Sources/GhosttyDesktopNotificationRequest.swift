import Foundation

/// Sendable payload copied at the synchronous Ghostty callback boundary. Remote byte
/// streams (the ssh-tmux mirror, cloud machine event streams) reuse it to enter the same
/// bounded ingress; they pass `hookDirectory: nil` (no local project hooks for a remote
/// emitter) and a non-local `origin`.
struct GhosttyDesktopNotificationRequest: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
    let hookDirectory: String?
    let title: String
    let body: String
    /// Host-owned text (a machine name); the terminal protocol carries no subtitle.
    let subtitle: String
    let origin: TerminalNotificationOrigin

    init(
        tabId: UUID,
        surfaceId: UUID?,
        hookDirectory: String?,
        title: String,
        body: String,
        subtitle: String = "",
        origin: TerminalNotificationOrigin = .local
    ) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.hookDirectory = hookDirectory
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.origin = origin
    }

    /// Rejects machine payloads before they can become sidebar text or run policy hooks.
    static func isMachinePayload(title: String, body: String) -> Bool {
        if title.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if (title + body).unicodeScalars.contains(where: {
            // Ordinary multiline text and tabs remain valid notification text.
            ($0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t")
                || (0x7f...0x9f).contains($0.value)
        }) {
            return true
        }
        let content = body.drop(while: { $0.isWhitespace || isInvisibleFormat($0) })
        guard let first = content.first, first == "{" || first == "[" else {
            return false
        }
        if (try? JSONSerialization.jsonObject(with: Data(content.utf8))) != nil {
            return true
        }
        // Ghostty truncates OSC bodies to 255 bytes, so a machine payload can
        // arrive as a container that never closes. Text that closes its bracket
        // and keeps going ("[ ] buy milk", "[1, 2] round") is a human label.
        let next = content.dropFirst().first(where: { !$0.isWhitespace })
        let opensLikeJSON = first == "{" && next == "\""
            || first == "[" && (next == "{" || next == "[" || next == "\"")
            || content.range(
                of: #"^\[\s*(?:-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null)\s*,"#,
                options: .regularExpression
            ) != nil
        guard opensLikeJSON else { return false }
        guard let closed = closedOutermostContainer(content) else { return true }
        // A complete object followed by more lines or bytes (NDJSON, a payload
        // with a suffix) is still machine output; "{\"name\"} is required" is not.
        let object = try? JSONSerialization.jsonObject(with: Data(closed.utf8)) as? [String: Any]
        return object.map { !$0.isEmpty } ?? false
    }

    /// Invisible format characters (zero-width, byte-order and direction marks)
    /// can lead a payload without changing its shape.
    private static func isInvisibleFormat(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
    }

    /// The text through the outermost bracket's close, ignoring brackets inside
    /// JSON strings, or nil when it never closes.
    private static func closedOutermostContainer(_ text: Substring) -> Substring? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.unicodeScalars.indices {
            let scalar = text.unicodeScalars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }
            switch scalar {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return text[...index] }
            default: break
            }
        }
        return nil
    }
}
