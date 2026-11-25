import Testing
@testable import CmuxNextApp

/// An incognito workspace's chats are deleted when it closes; a normal workspace's stay in history
/// (leo-workspace design/spaces.md "Incognito").
@MainActor
struct IncognitoChatsTests {
    private let incognito: Set<String> = ["incognito-workspace"]

    @Test func anIncognitoWorkspacesChatsArePurgedByItsKey() {
        let key = "3f2b8c1e-5d4a-4b6f-9e7d-0a1b2c3d4e5f"
        #expect(IncognitoChats.key(of: "incognito-workspace", key: key, incognito: incognito.contains) == key)
    }

    @Test func aNormalWorkspaceKeepsItsChats() {
        let key = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
        #expect(IncognitoChats.key(of: "normal-workspace", key: key, incognito: incognito.contains) == nil)
    }

    @Test func aWorkspaceWithNoKeyPurgesNothing() {
        #expect(IncognitoChats.key(of: "incognito-workspace", key: nil, incognito: incognito.contains) == nil)
        #expect(IncognitoChats.key(of: "incognito-workspace", key: "", incognito: incognito.contains) == nil)
    }
}
