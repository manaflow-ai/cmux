import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

@MainActor
enum BridgeFixture {
    struct Envelope: Decodable { var data: DaemonTree }

    static func store() throws -> DaemonStore {
        let url = try #require(Bundle.module.url(forResource: "list-workspaces", withExtension: "json", subdirectory: "Fixtures"))
        let tree = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).data
        let store = DaemonStore()
        store.apply(snapshot: tree)
        return store
    }
}

