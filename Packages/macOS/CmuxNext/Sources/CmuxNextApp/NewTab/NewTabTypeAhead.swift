import Foundation

/// `!` on the new tab screen (plans/cmux-next/new-tab.md section 3.2): the
/// page sends the command typed so far, whole each time, while the terminal
/// that replaces it is being made. The terminal gets it in order, edits
/// included, before the page closes, so no key is lost or typed twice.
@MainActor
final class NewTabTypeAhead {
    private var texts: [String: String] = [:]

    /// The page `key` now shows `text` after its `!`.
    func update(_ key: String, text: String) { texts[key] = text }

    func latest(_ key: String) -> String { texts[key] ?? "" }

    func forget(_ key: String) { texts[key] = nil }

    /// Sends what page `key` typed, then whatever was typed while that was
    /// sent, until nothing new arrived; then forgets the page. The caller
    /// closes the page in the same main-actor turn, so no key falls between.
    func drain(_ key: String, send: @MainActor (String) async throws -> Void) async throws {
        var sent = ""
        var typed = latest(key)
        // Ends when a send finishes with nothing new typed; each pass waits on the send.
        while sent != typed {
            try await send(Self.delta(sent: sent, typed: typed))
            sent = typed
            typed = latest(key)
        }
        forget(key)
    }

    /// What to type so a prompt showing `sent` shows `typed`: DEL (the
    /// shell's backspace) for each character after the common prefix, then
    /// the rest of `typed`.
    nonisolated static func delta(sent: String, typed: String) -> String {
        let common = zip(sent, typed).prefix { $0 == $1 }.count
        let erase = String(repeating: "\u{7f}", count: sent.count - common)
        return erase + String(typed.dropFirst(common))
    }
}
