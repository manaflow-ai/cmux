@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

private typealias WireJSON = CmuxNextDaemon.JSONValue

/// The wire golden of CmuxNextApp's one hand-written request (with
/// CmuxNextDaemonTests/StragglerRequestWireGoldenTests for the daemon's): `machine-listening-tcp`
/// sends no fields and is ungated, while the schema gates it on `machine-listening-tcp-v1`, which
/// the generated type takes from MethodTable.
struct MachineListeningTCPRequestWireGoldenTests {
    @Test func sendsItsGoldenLine() throws {
        let line = try JSONDecoder().decode(WireJSON.self, from: WireCoding.encodeRequest(MachineListeningTCPRequest(), id: 1))
        #expect(line == .object(["id": .number(1), "cmd": .string("machine-listening-tcp")]))
        #expect(MachineListeningTCPRequest.requiredCapability == nil)
    }

    /// The schema lists the command for the macos client with no request fields.
    @Test func schemaCommandHasNoFields() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above the test")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        let schema = try JSONDecoder().decode(WireJSON.self, from: data)
        guard case .object(let document) = schema, case .object(let commands)? = document["commands"],
              case .object(let spec)? = commands[MachineListeningTCPRequest.command] else {
            Issue.record("machine-listening-tcp is not in sdk-schema.json")
            return
        }
        guard case .array(let clients)? = spec["clients"] else {
            Issue.record("machine-listening-tcp lists no clients")
            return
        }
        #expect(clients.contains(.string("macos")))
        #expect(spec["capability"] == .string("machine-listening-tcp-v1"))
        if case .object(let request)? = spec["request"], case .object(let fields)? = request["fields"] {
            #expect(fields.isEmpty)
        }
    }
}
