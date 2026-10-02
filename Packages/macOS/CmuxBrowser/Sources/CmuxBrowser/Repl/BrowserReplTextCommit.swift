import Foundation

/// The text input client a REPL text insertion commits through, as an input
/// method sees it (`NSTextInputClient` on a web view in the app).
@MainActor
public protocol BrowserReplTextCommitTarget: AnyObject {
    /// Whether a composition is already in progress.
    var hasMarkedText: Bool { get }
    /// Whether the focused element takes composed text (a rich-text editor),
    /// once the engine's editor state, which gates marked text, is current.
    func prepareComposition() async -> Bool
    func setMarkedText(_ text: String)
    func insertText(_ text: String)
}

/// Commits text the way an input method does: as marked text that is then
/// confirmed when the focused element is a rich-text editor, so the page
/// sees `compositionstart`, `beforeinput`/`input` and `compositionend`;
/// otherwise as one plain insert. Text with a line break or a tab is never
/// composed (those are editing commands, not composed text).
@MainActor
public enum BrowserReplTextCommit {
    /// Commits `text` into `target`.
    /// - Parameter checkTarget: Decides whether the text may go to the
    ///   element that has focus; it throws to refuse, and then nothing is
    ///   committed.
    public static func commit(
        _ text: String,
        into target: some BrowserReplTextCommitTarget,
        checkTarget: @MainActor () async throws -> Void
    ) async throws {
        try await checkTarget()
        let composable = !text.contains { $0.isNewline || $0 == "\t" }
        if composable, !target.hasMarkedText, await target.prepareComposition() {
            target.setMarkedText(text)
        }
        target.insertText(text)
    }
}
