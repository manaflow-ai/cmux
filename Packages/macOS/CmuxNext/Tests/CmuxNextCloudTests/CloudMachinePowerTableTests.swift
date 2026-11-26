import CmuxNextCloud
import Foundation
import Testing

/// Replays cmux-cloud-machine's power table (`schemas/cloud-machine-power/table.json`, exported by
/// cmux-tui `crates/cmux-cloud-machine/src/power.rs` and kept fresh by its `power/tests.rs`) against
/// ``CloudMachine/Status`` (RFD 0026: "every other language replays it"). A status added to the
/// Rust machine but not here, or one left here after Rust drops it, fails this suite.
@Suite struct CloudMachinePowerTableTests {
    private struct Table: Decodable {
        struct State: Decodable {
            let state: String
            let status: String
            let inFlight: Bool
            let awaits: Bool
        }
        let version: Int
        let source: String
        let states: [State]
    }

    private static func table() throws -> Table {
        var root = URL(fileURLWithPath: #filePath)
        let path = "schemas/cloud-machine-power/table.json"
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no \(path) above \(#filePath)")
            root = parent
        }
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: root.appendingPathComponent(path)))
    }

    @Test func tableIsTheVersionThisReplayReads() throws {
        let table = try Self.table()
        #expect(table.version == 1)
        #expect(table.source == "cmux-tui/crates/cmux-cloud-machine/src/power.rs")
    }

    @Test func statusHasExactlyTheTablesStatuses() throws {
        let tableStatuses = Set(try Self.table().states.map(\.status))
        let swiftStatuses = Set(CloudMachine.Status.allCases.map(\.rawValue))
        #expect(swiftStatuses.subtracting(tableStatuses).isEmpty, "Swift statuses the power table lacks")
        #expect(tableStatuses.subtracting(swiftStatuses).isEmpty, "power table statuses Swift lacks")
    }

    @Test func everyTableStatusDecodesAsItself() throws {
        for state in try Self.table().states {
            let data = Data("\"\(state.status)\"".utf8)
            let status = try JSONDecoder().decode(CloudMachine.Status.self, from: data)
            #expect(status.rawValue == state.status, "table state \(state.state)")
        }
    }
}
