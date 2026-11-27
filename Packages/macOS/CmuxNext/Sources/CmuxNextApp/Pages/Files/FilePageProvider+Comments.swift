import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The markdown page's viewer comments (viewer-comments-DESIGN.md "Comments in the viewer"): kept
/// with the file through ``comments`` (its extended attribute and an app-side copy, like table
/// widths), sent in the config as `comments`, and again on every change.
extension FilePageProvider {
    /// The saved comments of `url` as the page's JSON object, or nil.
    func savedComments(_ url: URL) async -> JSONValue? {
        guard let comments, let data = await comments.read(url.path) else { return nil }
        return await Self.commentJSON(data, keepEmpty: false)
    }

    /// Keeps `quote`'s comment with this tab's file and shows it in the page; false when the quote
    /// is not this file's, has no lines or no comment, or nothing could store it.
    @discardableResult
    func addComment(_ quote: ChatQuote, id: String = UUID().uuidString) async -> Bool {
        guard kind == .markdown, let file, canonical(URL(fileURLWithPath: quote.source)) == file else { return false }
        guard let comments, let result = await comments.add(quote, id: id, at: file.path) else { return false }
        await publishComments(result, for: file)
        return result.written.attribute || result.written.fallback
    }

    /// `cmux.markdown.deleteComment {path, id}`: forgets one comment; answers whether it was there.
    func deleteComment(_ params: JSONValue) async throws -> JSONValue {
        let url = try path(params["path"])
        guard let file, canonical(url) == file else { throw PageError.invalidParams("path is not this page's file") }
        guard let id = params["id"]?.stringValue else { throw PageError.invalidParams("id must be a string") }
        guard let comments, let result = await comments.remove(id, at: file.path) else { return ["removed": false] }
        await publishComments(result, for: file)
        return ["removed": .bool(result.written.attribute || result.written.fallback)]
    }

    /// Publishes only the newest persisted mutation. Parsing is concurrent work, so this check is
    /// repeated after the await before the page callback can apply a stale list.
    private func publishComments(_ result: MarkdownCommentPersistenceResult, for file: URL) async {
        guard self.file == file else { return }
        guard let value = await Self.commentJSON(result.data, keepEmpty: true) else { return }
        guard self.file == file, result.sequence > latestCommentsSequence else { return }
        latestCommentsSequence = result.sequence
        onCommentsChanged?(value)
    }

    /// Decode and encode the bounded list away from the page's main actor. The encoded value is
    /// sent to the page only after the persistence actor has completed its write attempt.
    @concurrent nonisolated private static func commentJSON(_ data: Data, keepEmpty: Bool) async -> JSONValue? {
        guard let list = ViewerCommentList(data: data), keepEmpty || !list.comments.isEmpty else { return nil }
        return try? JSONValue.parse(list.data)
    }
}
