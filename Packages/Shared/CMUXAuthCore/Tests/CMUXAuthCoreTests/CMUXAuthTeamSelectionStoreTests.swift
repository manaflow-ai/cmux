import CMUXAuthCore
import Foundation
import Testing

@Suite struct CMUXAuthTeamSelectionStoreTests {
    @Test func roundTripsSelection() {
        let store = CMUXAuthTeamSelectionStore(
            keyValueStore: SelectionTestKeyValueStore(),
            key: "selected_team"
        )
        store.selectedTeamID = "team_a"
        #expect(store.selectedTeamID == "team_a")
    }

    @Test func normalizesEmptyAndWhitespaceToNil() {
        let store = CMUXAuthTeamSelectionStore(
            keyValueStore: SelectionTestKeyValueStore(),
            key: "selected_team"
        )
        store.selectedTeamID = "  team_a  "
        #expect(store.selectedTeamID == "team_a")

        store.selectedTeamID = "   "
        #expect(store.selectedTeamID == nil)
    }

    @Test func nilAssignmentAndClearRemoveValue() {
        let backing = SelectionTestKeyValueStore()
        let store = CMUXAuthTeamSelectionStore(keyValueStore: backing, key: "selected_team")
        store.selectedTeamID = "team_a"
        store.selectedTeamID = nil
        #expect(backing.string(forKey: "selected_team") == nil)

        store.selectedTeamID = "team_b"
        store.clear()
        #expect(store.selectedTeamID == nil)
    }
}

private final class SelectionTestKeyValueStore: CMUXAuthKeyValueStore {
    private var storage: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}
