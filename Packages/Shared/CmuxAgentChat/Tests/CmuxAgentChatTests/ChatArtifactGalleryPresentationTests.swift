import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery presentation")
struct ChatArtifactGalleryPresentationTests {
    @Test("filtering preserves group order and hides rows within every group")
    func filterPreservesGroups() {
        let snapshot = gallerySnapshot(
            created: [item("/created/App.swift", kind: .text, size: 10)],
            attached: [item("/attached/photo.png", kind: .image, size: 20)],
            referenced: [
                item("/referenced/notes.txt", kind: .text, size: 30),
                item("/referenced/Tool.swift", kind: .text, size: 40),
            ]
        )

        let presentation = ChatArtifactGalleryPresentation(
            snapshot: snapshot,
            filter: .code
        )

        #expect(presentation.groups.map(\.kind) == [.created, .attached, .referenced])
        #expect(presentation.items(in: .created).map(\.displayName) == ["App.swift"])
        #expect(presentation.items(in: .attached).isEmpty)
        #expect(presentation.items(in: .referenced).map(\.displayName) == ["Tool.swift"])
    }

    @Test("name and size sorts reorder only within each group")
    func sortWithinGroups() {
        let created = [
            item("/created/zeta.txt", kind: .text, size: nil),
            item("/created/Alpha.txt", kind: .text, size: 1),
            item("/created/middle.txt", kind: .text, size: 30),
        ]
        let referenced = [
            item("/referenced/b.txt", kind: .text, size: 5),
            item("/referenced/a.txt", kind: .text, size: 10),
        ]
        let snapshot = gallerySnapshot(created: created, referenced: referenced)

        let named = ChatArtifactGalleryPresentation(snapshot: snapshot, sort: .name)
        #expect(named.items(in: .created).map(\.displayName) == ["Alpha.txt", "middle.txt", "zeta.txt"])
        #expect(named.items(in: .referenced).map(\.displayName) == ["a.txt", "b.txt"])

        let sized = ChatArtifactGalleryPresentation(snapshot: snapshot, sort: .size)
        #expect(sized.items(in: .created).map(\.displayName) == ["middle.txt", "Alpha.txt", "zeta.txt"])
        #expect(sized.items(in: .referenced).map(\.displayName) == ["a.txt", "b.txt"])
    }

    private func gallerySnapshot(
        created: [ChatArtifactGalleryItem] = [],
        attached: [ChatArtifactGalleryItem] = [],
        referenced: [ChatArtifactGalleryItem] = []
    ) -> ChatArtifactGallerySnapshot {
        ChatArtifactGallerySnapshot(page: ChatArtifactGalleryPage(
            sessionID: "session",
            created: created,
            attached: attached,
            referenced: referenced,
            referencedTotal: referenced.count,
            generation: "generation"
        ))
    }

    private func item(
        _ path: String,
        kind: ChatArtifactKind,
        size: Int64?
    ) -> ChatArtifactGalleryItem {
        ChatArtifactGalleryItem(
            path: path,
            kind: kind,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            size: size
        )
    }
}
