import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrAssociationStoreTests {
    private func store() throws -> (RemoteHerdrAssociationStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-assoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xdg = root.appendingPathComponent("xdg")
        let native = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let store = RemoteHerdrAssociationStore(
            directories: [
                xdg.appendingPathComponent("cmux-herdr"),
                native,
            ]
        )
        return (store, root)
    }

    @Test func lockTitlePersistsPluginFormat() throws {
        let (store, _) = try store()
        let entry = store.lockTitle(
            fingerprint: "fp",
            paneID: "w2:p1",
            title: "Orchestrator",
            authority: NestedTitleAuthority.user.rawValue
        )
        #expect(entry["title_lock"] as? Bool == true)
        #expect(entry["locked_title"] as? String == "Orchestrator")
        #expect(store.lockedTitle(fingerprint: "fp", paneID: "w2:p1") == "Orchestrator")
        #expect(store.isTitleLocked(fingerprint: "fp", paneID: "w2:p1"))

        let path = store.directories[0].appendingPathComponent("associations-fp.json")
        let data = try Data(contentsOf: path)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        let panes = try #require(object["panes"] as? [String: Any])
        let pane = try #require(panes["w2:p1"] as? [String: Any])
        #expect(pane["title_lock"] as? Bool == true)
        #expect(pane["locked_title"] as? String == "Orchestrator")
        // Second directory gets a copy for Application Support readers.
        #expect(
            FileManager.default.fileExists(
                atPath: store.directories[1].appendingPathComponent("associations-fp.json").path
            )
        )
    }

    @Test func unlockClearsLockFields() throws {
        let (store, _) = try store()
        _ = store.lockTitle(fingerprint: "fp", paneID: "w2:p1", title: "A")
        let unlocked = store.unlockTitle(fingerprint: "fp", paneID: "w2:p1")
        #expect(unlocked?["title_lock"] as? Bool == false)
        #expect(store.lockedTitle(fingerprint: "fp", paneID: "w2:p1") == nil)
    }

    @Test func readsPluginWrittenDocument() throws {
        let (store, _) = try store()
        let path = store.directories[0].appendingPathComponent("associations-fp.json")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pluginDoc: [String: Any] = [
            "version": 1,
            "panes": [
                "w2:p9": [
                    "pane_id": "w2:p9",
                    "title_lock": true,
                    "locked_title": "From Plugin",
                    "status_key": "herdr:w2:p9",
                ],
            ],
            "mirrors": [String: Any](),
            "host_fingerprint_key": "fp",
        ]
        let data = try JSONSerialization.data(withJSONObject: pluginDoc, options: [.prettyPrinted])
        try data.write(to: path)
        #expect(store.lockedTitle(fingerprint: "fp", paneID: "w2:p9") == "From Plugin")
    }
}
