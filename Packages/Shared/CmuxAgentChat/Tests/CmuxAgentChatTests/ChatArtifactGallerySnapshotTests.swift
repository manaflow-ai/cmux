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
            referenced: [created, attached, referenced, next, next],
            referencedTotal: 2,
            generation: "generation"
        )

        let snapshot = ChatArtifactGallerySnapshot(page: initial).appending(page)

        #expect(snapshot.created.map(\.path) == [created.path])
        #expect(snapshot.attached.map(\.path) == [attached.path])
        #expect(snapshot.referenced.map(\.path) == [referenced.path, next.path])
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
