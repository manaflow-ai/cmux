@testable import CmuxNextPages
import Foundation
import Testing

/// A file's viewer comments: added from Comment…, kept as one bounded value, removed by Delete
/// (viewer-comments-DESIGN.md "Comments in the viewer").
struct ViewerCommentListTests {
    static func quote(_ line: Int, comment: String = "Why?") -> ChatQuote {
        ChatQuote(source: "/r/a.md", kind: .markdown, lines: line...(line + 1), quoted: "text \(line)", comment: comment)
    }

    @Test func aCommentKeepsItsLinesQuoteAndTextAndSurvivesTheRoundTrip() throws {
        var list = ViewerCommentList()
        let added = list.add(Self.quote(3), id: "c1")
        #expect(added)
        #expect(list.comments == [ViewerComment(id: "c1", startLine: 3, endLine: 4, quoted: "text 3", comment: "Why?")])
        let back = try #require(ViewerCommentList(data: list.data))
        #expect(back == list)
    }

    @Test func aQuoteWithoutLinesOrCommentIsNotKept() {
        var list = ViewerCommentList()
        let noLines = list.add(ChatQuote(source: "/r/a.md", kind: .markdown, quoted: "x", comment: "c"), id: "a")
        let noComment = list.add(Self.quote(1, comment: "  "), id: "b")
        #expect(!noLines && !noComment)
        #expect(list.comments.isEmpty)
    }

    @Test func pastTheLimitTheOldestGoesAndLongTextIsCut() {
        var list = ViewerCommentList()
        for index in 0...ViewerCommentList.limit { list.add(Self.quote(index + 1), id: "c\(index)") }
        #expect(list.comments.count == ViewerCommentList.limit)
        #expect(list.comments.first?.id == "c1")
        list.add(Self.quote(1, comment: String(repeating: "x", count: ViewerCommentList.commentLimit + 50)), id: "long")
        #expect(list.comments.last?.comment.count == ViewerCommentList.commentLimit)
    }

    @Test func removeDropsOnlyThatComment() {
        var list = ViewerCommentList()
        list.add(Self.quote(1), id: "a")
        list.add(Self.quote(5), id: "b")
        let first = list.remove("a")
        let again = list.remove("a")
        #expect(first && !again)
        #expect(list.comments.map(\.id) == ["b"])
    }

    @Test func otherJSONIsNotAList() {
        #expect(ViewerCommentList(data: Data(#"{"v":2,"comments":[]}"#.utf8)) == nil)
        #expect(ViewerCommentList(data: Data("nope".utf8)) == nil)
    }
}
