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

    @Test("missing files are omitted from every group by default")
    func omitsMissingFilesByDefault() {
        let snapshot = gallerySnapshot(
            created: [
                item("/created/present.txt", kind: .text, size: 1),
                item("/created/missing.txt", kind: .text, size: nil, exists: false),
            ],
            attached: [
                item("/attached/missing.png", kind: .image, size: nil, exists: false),
            ],
            referenced: [
                item("/referenced/present.log", kind: .text, size: 2),
                item("/referenced/missing.log", kind: .text, size: nil, exists: false),
            ]
        )

        let presentation = ChatArtifactGalleryPresentation(snapshot: snapshot)

        #expect(presentation.items(in: .created).map(\.displayName) == ["present.txt"])
        #expect(presentation.items(in: .attached).isEmpty)
        #expect(presentation.items(in: .referenced).map(\.displayName) == ["present.log"])
        #expect(ChatArtifactGallerySwipeOrder(groups: presentation.groups).paths == [
            "/created/present.txt",
            "/referenced/present.log",
        ])
    }

    @Test("missing files can be restored across every group")
    func includesMissingFilesOnRequest() {
        let missingCreated = item("/created/missing.txt", kind: .text, size: nil, exists: false)
        let missingAttached = item("/attached/missing.png", kind: .image, size: nil, exists: false)
        let missingReferenced = item("/referenced/missing.log", kind: .text, size: nil, exists: false)
        let presentation = ChatArtifactGalleryPresentation(
            snapshot: gallerySnapshot(
                created: [missingCreated],
                attached: [missingAttached],
                referenced: [missingReferenced]
            ),
            includesMissingFiles: true
        )

        #expect(presentation.items(in: .created) == [missingCreated])
        #expect(presentation.items(in: .attached) == [missingAttached])
        #expect(presentation.items(in: .referenced) == [missingReferenced])
        #expect(ChatArtifactGallerySwipeOrder(groups: presentation.groups).paths == [
            missingCreated.path,
            missingAttached.path,
            missingReferenced.path,
        ])
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
        size: Int64?,
        exists: Bool = true
    ) -> ChatArtifactGalleryItem {
        ChatArtifactGalleryItem(
            path: path,
            kind: kind,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            size: size,
            exists: exists
        )
    }
}
