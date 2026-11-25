import Foundation
import Testing
@testable import CmuxMobileModel

@MainActor
struct LastKnownListStoreTests {
    @Test func relaunchRestoresTheLastSuccessfulResultIncludingEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LastKnownListStore(directory: directory)
        let members = store.list(accountID: "a", teamID: "t", screen: "members")
        #expect(members.read([String].self) == nil)
        members.save(["First"])
        #expect(members.read([String].self) == ["First"])
        members.save([String]())
        store.flush()
        let reopened = LastKnownListStore(directory: directory)
        #expect(reopened.list(accountID: "a", teamID: "t", screen: "members").read([String].self) == [])
    }

    @Test func accountTeamScreenAndBackendStayIsolatedOnDisk() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = LastKnownListStore(directory: directory)
        writer.list(accountID: "a/b", teamID: nil, screen: "list", context: ["a", "b"]).save(["private"])
        writer.flush()
        let reader = LastKnownListStore(directory: directory)
        #expect(reader.list(accountID: "a/b", screen: "list", context: ["a", "b"]).read([String].self) == ["private"])
        for other in [
            reader.list(accountID: "a_b", screen: "list", context: ["a", "b"]),
            reader.list(accountID: "a/b", teamID: "", screen: "list", context: ["a", "b"]),
            reader.list(accountID: "a/b", screen: "List", context: ["a", "b"]),
            reader.list(accountID: "a/b", screen: "list", context: ["a/b"]),
        ] {
            #expect(other.read([String].self) == nil)
        }
    }

    @Test func signOutDropsAnInFlightRefreshAndErasesDisk() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LastKnownListStore(directory: directory)
        let old = store.list(accountID: "account", screen: "chats")
        old.save(["before"])
        store.removeAll()
        old.save(["late reply"])
        #expect(old.read([String].self) == nil)
        store.flush()
        let reopened = LastKnownListStore(directory: directory)
        #expect(reopened.list(accountID: "account", screen: "chats").read([String].self) == nil)
    }
}
