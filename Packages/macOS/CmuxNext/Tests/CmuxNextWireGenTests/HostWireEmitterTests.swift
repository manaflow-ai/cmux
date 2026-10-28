import Foundation
import Testing
@testable import CmuxNextWireGen

private func hostWireSchema() throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/chromium-host-wire.json"))
}

/// The real schema with `edit` applied to its JSON object.
private func editedSchema(_ edit: (inout [String: Any]) -> Void) throws -> Data {
    var document = try #require(try JSONSerialization.jsonObject(with: hostWireSchema()) as? [String: Any])
    edit(&document)
    return try JSONSerialization.data(withJSONObject: document)
}

/// The Chromium host wire's Swift codec (task p05-ipc-181): HostWireEmitter writes ChromiumHostFrame from
/// cmux-tui/spec/chromium-host-wire.json, the schema host_wire_cpp.py builds the C++ codec from, and
/// refuses the layouts host_wire.py refuses. ChromiumHostFrameTests runs the emitted codec on the golden frames.
@Suite struct HostWireEmitterTests {
    @Test func emitsTheFrameStructFromTheSchema() throws {
        let emitter = try HostWireEmitter(schema: hostWireSchema())
        #expect(emitter.headerSize == 64)
        #expect(emitter.fields.map(\.offset) == [0, 4, 8, 32, 40, 48, 56, 58, 60])
        let source = emitter.source()
        for line in [
            "#if DEBUG || CMUX_BENCH_HOOKS",
            "nonisolated struct ChromiumHostFrame: Equatable, Sendable {",
            "        case wheel = 4",
            "        case inputPresented = 110",
            "    static let headerSize = 64",
            "    static let maxPayload = 65536",
            "    static let wheelPrecise: UInt64 = 0x8000000000000000",
            "    static let wheelDeltaScale: Int32 = 100",
            "    var rawKind: UInt32",
            "    var v: [Int32] = [0, 0, 0, 0, 0, 0]",
            "        put(UInt32(payload.count))",
            "        for index in 0..<6 { put(UInt32(bitPattern: index < v.count ? v[index] : 0)) }",
            "        frame.v = (0..<6).map { Int32(bitPattern: get(8 + 4 * $0, UInt32.self)) }",
            "        frame.seq = get(60, UInt32.self)",
            "#endif",
        ] {
            #expect(source.contains(line + "\n"), "missing: \(line)")
        }
        // The payload length is `payload.count`, never a stored field of its own.
        #expect(!source.contains("var payload: UInt32"))
    }

    @Test func emitsTheSameBytesEveryRun() throws {
        #expect(try HostWireEmitter(schema: hostWireSchema()).source() == HostWireEmitter(schema: hostWireSchema()).source())
    }

    /// Each refusal names the JSON path, as host_wire.py's do.
    @Test func refusesLayoutsNeitherCodecCanBuild() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("$.header", { document in
                var header = document["header"] as? [String: Any] ?? [:]
                header["size"] = 72
                document["header"] = header
            }),
            ("$.header.fields[7]", { document in
                var header = document["header"] as? [String: Any] ?? [:]
                var fields = header["fields"] as? [[String: Any]] ?? []
                fields[6]["type"] = "u8"
                fields[7]["type"] = "u32"
                header["fields"] = fields
                document["header"] = header
            }),
            ("$.kinds[1].value", { document in
                var kinds = document["kinds"] as? [[String: Any]] ?? []
                kinds[1]["value"] = 1
                document["kinds"] = kinds
            }),
            ("$.constants[0].name", { document in
                var constants = document["constants"] as? [[String: Any]] ?? []
                constants[0]["name"] = "rawKind"
                document["constants"] = constants
            }),
            ("$.constants[0].value", { document in
                var constants = document["constants"] as? [[String: Any]] ?? []
                constants[0]["value"] = "0x100000000"
                document["constants"] = constants
            }),
            ("$.header.fields", { document in
                var header = document["header"] as? [String: Any] ?? [:]
                var fields = header["fields"] as? [[String: Any]] ?? []
                fields[1]["role"] = "kind"  // two kinds and no payload length
                header["fields"] = fields
                document["header"] = header
            }),
        ]
        for (path, edit) in cases {
            do {
                _ = try HostWireEmitter(schema: editedSchema(edit))
                Issue.record("not refused: \(path)")
            } catch let error as HostWireSchemaError {
                #expect(error.path == path, "\(error)")
            }
        }
    }

    /// The plugin's CmuxNextBrowser command gives only the host wire; it reads neither daemon schema.
    @Test func argumentsTakeAHostWireOnlyRun() throws {
        let run = try WireGenArguments(["--host-wire", "w.json", "--host-wire-output", "w.swift"])
        #expect(run.hostWireOutput?.lastPathComponent == "w.swift")
        #expect(run.schemas == nil)
        for (argv, expected) in [
            (["--host-wire", "w.json"], "no output"),
            (["--host-wire-output", "w.swift"], "--host-wire and --host-wire-output go together"),
            (["--host-wire", "w.json", "--host-wire-output", "w.swift", "--identity-output", "i.swift"], "missing --sdk-schema"),
        ] {
            do {
                _ = try WireGenArguments(argv)
                Issue.record("not refused: \(argv)")
            } catch {
                #expect("\(error)".hasPrefix(expected), "\(argv): \(error)")
            }
        }
    }
}
