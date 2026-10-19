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
        let content = body.drop(while: { $0.isWhitespace })
        guard let first = content.first, first == "{" || first == "[" else {
            return false
        }
        if (try? JSONSerialization.jsonObject(with: Data(content.utf8))) != nil {
            return true
        }
        // Ghostty truncates OSC bodies to 255 bytes. Recognize container prefixes
        // even when closing bytes are lost, without rejecting labels like "[build]".
        let next = content.dropFirst().first(where: { !$0.isWhitespace })
        if first == "{" && (next == "\"" || next == "}")
            || first == "[" && (next == "{" || next == "[" || next == "\"" || next == "]") {
            return true
        }
        // A closed numeric array already parsed above. Requiring a comma here
        // preserves human labels such as "[1] done" while catching truncated lists.
        return content.range(
            of: #"^\[\s*(?:-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\s*,|(?:true|false|null)\s*[,\]])"#,
            options: .regularExpression
        ) != nil
    }
}
