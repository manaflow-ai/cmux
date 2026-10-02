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
    ///
    /// `checkTarget` runs last before the first commit step, after the wait
    /// for the editor state, because the page can move focus during that
    /// wait (into another origin's frame, say), and the text goes wherever
    /// focus is when it is committed. The marked text and the insert follow
    /// on the same main-actor turn, so nothing in this process runs between
    /// them. The page's own process can still move focus after the check's
    /// last reply and before the insert reaches it; the engine has no insert
    /// bound to an element or frame that would close that window.
    /// - Parameter checkTarget: Decides whether the text may go to the
    ///   element that has focus; it throws to refuse, and then nothing is
    ///   committed.
    public static func commit(
        _ text: String,
        into target: some BrowserReplTextCommitTarget,
        checkTarget: @MainActor () async throws -> Void
    ) async throws {
        let composable = !text.contains { $0.isNewline || $0 == "\t" }
        var composes = false
        if composable, !target.hasMarkedText {
            composes = await target.prepareComposition()
        }
        try await checkTarget()
        if composes { target.setMarkedText(text) }
        target.insertText(text)
    }
}
