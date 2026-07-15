import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery snapshot")
struct ChatArtifactGallerySnapshotTests {
    @Test("appending drops paths already present in any section")
    func appendingDeduplicatesAcrossSections() {
        let created = item(path: "/session/created.txt", provenance: .created)
        let attached = item(path: "/session/attached.txt", provenance: .attached)
        let referenced = item(path: "/session/referenced.txt", provenance: .referenced)
        let next = item(path: "/session/next.txt", provenance: .referenced)
        let initial = ChatArtifactGalleryPage(
            sessionID: "session",
            created: [created],
            attached: [attached],
            referenced: [referenced],
            referencedTotal: 2,
            nextCursor: "next",
            generation: "generation"
        )
        let page = ChatArtifactGalleryPage(
            sessionID: "session",
            created: [created, item(path: "/session/created-next.txt", provenance: .created)],
            createdTotal: 2,
            attached: [attached, item(path: "/session/attached-next.txt", provenance: .attached)],
            attachedTotal: 2,
            referenced: [created, attached, referenced, next, next],
            referencedTotal: 2,
            generation: "generation"
        )

        let snapshot = ChatArtifactGallerySnapshot(page: initial).appending(page)

        #expect(snapshot.created.map(\.path) == [created.path, "/session/created-next.txt"])
        #expect(snapshot.attached.map(\.path) == [attached.path, "/session/attached-next.txt"])
        #expect(snapshot.referenced.map(\.path) == [referenced.path, next.path])
        #expect(snapshot.createdTotal == 2)
        #expect(snapshot.attachedTotal == 2)
    }

    private func item(
        path: String,
        provenance: ChatArtifactProvenance
    ) -> ChatArtifactGalleryItem {
        ChatArtifactGalleryItem(
            path: path,
            kind: .text,
            displayName: (path as NSString).lastPathComponent,
            provenance: provenance
        )
    }
}
