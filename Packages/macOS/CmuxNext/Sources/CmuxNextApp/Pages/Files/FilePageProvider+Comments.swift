import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The markdown page's viewer comments (viewer-comments-DESIGN.md "Comments in the viewer"): kept
/// with the file through ``comments`` (its extended attribute and an app-side copy, like table
/// widths), sent in the config as `comments`, and again on every change.
extension FilePageProvider {
    /// The saved comments of `url` as the page's JSON object, or nil.
    func savedComments(_ url: URL) async -> JSONValue? {
        guard let list = await commentList(url.path), !list.comments.isEmpty else { return nil }
        return try? JSONValue.parse(list.data)
    }

    /// Keeps `quote`'s comment with this tab's file and shows it in the page; false when the quote
    /// is not this file's, has no lines or no comment, or nothing could store it.
    @discardableResult
    func addComment(_ quote: ChatQuote, id: String = UUID().uuidString) async -> Bool {
        guard kind == .markdown, let file, Self.canonical(URL(fileURLWithPath: quote.source)) == file else { return false }
        var list = await commentList(file.path) ?? ViewerCommentList()
        guard list.add(quote, id: id) else { return false }
        return await save(list, at: file)
    }

    /// `cmux.markdown.deleteComment {path, id}`: forgets one comment; answers whether it was there.
    func deleteComment(_ params: JSONValue) async throws -> JSONValue {
        let url = try path(params["path"])
        guard let file, Self.canonical(url) == file else { throw PageError.invalidParams("path is not this page's file") }
        guard let id = params["id"]?.stringValue else { throw PageError.invalidParams("id must be a string") }
        guard var list = await commentList(file.path), list.remove(id) else { return ["removed": false] }
        return ["removed": .bool(await save(list, at: file))]
    }

    private func commentList(_ path: String) async -> ViewerCommentList? {
        guard let comments, let data = await comments.read(path) else { return nil }
        return ViewerCommentList(data: data)
    }

    /// Writes `list` (dropping the oldest until it fits the store) and sends it to the page.
    private func save(_ list: ViewerCommentList, at file: URL) async -> Bool {
        guard let comments else { return false }
        var list = list
        list.trim(toBytes: MarkdownTableWidthRepository.commentsValueLimit)
        let written = await comments.write(file.path, list.comments.isEmpty ? nil : list.data)
        if let value = try? JSONValue.parse(list.data) { onCommentsChanged?(value) }
        return written.attribute || written.fallback
    }
}
