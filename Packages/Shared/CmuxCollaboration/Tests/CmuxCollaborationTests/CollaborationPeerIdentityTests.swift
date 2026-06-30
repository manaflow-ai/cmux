import CmuxCollaboration
import Foundation
import Testing

@Suite
struct CollaborationPeerIdentityTests {
    @Test
    func ephemeralIdentitiesAreDistinctForSeparateLocalPeers() throws {
        let firstUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        let first = CollaborationPeerIdentity.ephemeral(
            displayName: "Dorsa",
            colorPalette: ["#111111"],
            idProvider: { firstUUID }
        )
        let second = CollaborationPeerIdentity.ephemeral(
            displayName: "Dorsa",
            colorPalette: ["#111111"],
            idProvider: { secondUUID }
        )

        #expect(first.peerID != second.peerID)
        #expect(first.displayName == second.displayName)
        #expect(first.color == "#111111")
        #expect(second.color == "#111111")
    }

    @Test
    func emptyPaletteFallsBackToDefaultColor() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))

        let identity = CollaborationPeerIdentity.ephemeral(
            displayName: "Dorsa",
            colorPalette: [],
            idProvider: { uuid }
        )

        #expect(CollaborationPeerIdentity.defaultColorPalette.contains(identity.color))
    }
}
