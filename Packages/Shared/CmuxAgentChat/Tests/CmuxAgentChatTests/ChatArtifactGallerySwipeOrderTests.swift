import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery swipe order")
struct ChatArtifactGallerySwipeOrderTests {
    @Test("flattens visible groups and skips folders")
    func flattensVisibleFiles() {
        let first = item("/created/first.swift")
        let folder = item("/attached/folder", kind: .directory)
        let second = item("/attached/second.png", kind: .image)
        let third = item("/referenced/third.log")
        let order = ChatArtifactGallerySwipeOrder(groups: [
            ChatArtifactGalleryGroup(kind: .created, items: [first]),
            ChatArtifactGalleryGroup(kind: .attached, items: [folder, second]),
            ChatArtifactGalleryGroup(kind: .referenced, items: [third, first]),
        ])

        #expect(order.paths == [first.path, second.path, third.path])
    }

    @Test("next and previous stop at visible boundaries")
    func nextPreviousBoundaries() {
        let first = item("/first")
        let middle = item("/middle")
        let last = item("/last")
        let order = ChatArtifactGallerySwipeOrder(items: [first, middle, last])

        #expect(order.previousPath(before: first.path) == nil)
        #expect(order.nextPath(after: first.path) == middle.path)
        #expect(order.previousPath(before: middle.path) == first.path)
        #expect(order.nextPath(after: middle.path) == last.path)
        #expect(order.previousPath(before: last.path) == middle.path)
        #expect(order.nextPath(after: last.path) == nil)
        #expect(order.nextPath(after: "/unknown") == nil)
        #expect(order.previousPath(before: "/unknown") == nil)
    }

    @Test("keeps only adjacent pages alive around the current file")
    func boundsPageWindow() {
        let first = item("/first")
        let second = item("/second")
        let third = item("/third")
        let fourth = item("/fourth")
        let order = ChatArtifactGallerySwipeOrder(items: [first, second, third, fourth])

        #expect(order.pageWindow(around: first.path).map(\.path) == [first.path, second.path])
        #expect(order.pageWindow(around: second.path).map(\.path) == [first.path, second.path, third.path])
        #expect(order.pageWindow(around: fourth.path).map(\.path) == [third.path, fourth.path])
        #expect(order.pageWindow(around: "/unknown").isEmpty)
    }

    @Test("terminal references preserve order while excluding folders")
    func buildsFromTerminalReferences() {
        let references = [
            TerminalArtifactReference(path: "/first", kind: .text, displayName: "first"),
            TerminalArtifactReference(path: "/folder", kind: .directory, displayName: "folder"),
            TerminalArtifactReference(path: "/last", kind: .image, displayName: "last"),
        ]

        #expect(ChatArtifactGallerySwipeOrder(references: references).paths == ["/first", "/last"])
    }

    private func item(
        _ path: String,
        kind: ChatArtifactKind = .text
    ) -> ChatArtifactGalleryItem {
        ChatArtifactGalleryItem(
            path: path,
            kind: kind,
            displayName: path
        )
    }
}
