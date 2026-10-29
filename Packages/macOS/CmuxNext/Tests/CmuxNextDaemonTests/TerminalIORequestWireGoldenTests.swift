import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/TerminalIO: the
/// line each one sends today is recorded in cmux-tui/spec/fixtures/terminal-io-requests/lines.json and
/// compared here as JSON (key order does not count). The migration to the generated `<Name>Request`
/// types (CmuxNextWireGen RequestEmitter) must keep these goldens green. The daemon side reads the same
/// file (cmux-tui-core server/cmd_terminal_io_wire_tests.rs): it parses every line with the server's
/// own `Request` parse and sends each `echo` line to a terminal whose PTY writes are recorded, so the
/// bytes the app encodes are the bytes that reach the PTY.
///
/// No TerminalIO field holds caller-authored keys (WireKeyInventory.dictionaryFields): the snake-case
/// strategy and the generated CodingKeys write the same names, so every golden stays byte for byte. A
/// hand-written `nil` becomes the generated `FieldUpdate.unchanged`, which also leaves the key out.
struct TerminalIORequestWireGoldenTests {
    /// A request of the directory, encoded the way `DaemonConnection` sends it.
    struct Encoded: Sendable {
        /// The request's Swift type: two types can share one wire command (`send`).
        let type: String
        let encode: @Sendable () throws -> Data

        init<R: DaemonRequest>(_ request: R) {
            type = String(describing: R.self)
            encode = { try WireCoding.encodeRequest(request, id: 1) }
        }
    }

    private static let surface = SurfaceID(rawValue: 7)

    /// The request each fixture entry records, by its `name`.
    static let requests: [String: Encoded] = [
        "send text": Encoded(SendInputRequest(surface: surface, text: "ls\r")),
        "send with every field": Encoded(SendInputRequest(
            surface: surface, text: "yes", bytes: Data("a".utf8), paste: true,
            expectForeground: "/usr/local/bin/claude", flow: (4242 << 32) | 7
        )),
        "send bytes by terminal": Encoded(SendTerminalInputRequest(terminalID: "t1", bytes: Data([0x1B, 0x5B, 0x41]))),
        "send-key": Encoded(SendKeyRequest(surface: surface, keys: ["ctrl+c", "enter"])),
        "attach-surface without a surface": Encoded(AttachSurfaceRequest(surface: nil, size: nil)),
        "attach-surface sized byte replay": Encoded(AttachSurfaceRequest(surface: surface, size: CellSize(cols: 80, rows: 24))),
        "attach-surface with every field": Encoded(AttachSurfaceRequest(
            surface: surface, expectedGeneration: DaemonGeneration(rawValue: "gen-1"),
            expectedTerminalID: ResourceID(rawValue: "term_abc"), size: CellSize(cols: 80, rows: 24),
            snapshotVersion: 3, snapshotLocalHistory: true, snapshotImages: true
        )),
        "clear-history": Encoded(ClearHistoryRequest(surface: surface)),
        "clear-history with the Cmd-K fallback": Encoded(ClearHistoryRequest(surface: surface, fallbackKey: .command("k"))),
        "terminal-clipboard-subscribe": Encoded(TerminalClipboardSubscribeRequest(terminalIDs: ["term_a", "term_b"])),
        "terminal-clipboard-reply granting": Encoded(TerminalClipboardReplyRequest(requestID: "r-1", text: "clip")),
        "terminal-clipboard-reply refusing": Encoded(TerminalClipboardReplyRequest(requestID: "r-1", text: nil)),
        "release-attached-view-size": Encoded(ReleaseAttachedViewSizeRequest(surface: surface, lease: "l-1")),
        "set-size-counts off": Encoded(SetSizeCountsRequest(surface: surface, lease: "l-1", counts: false)),
        "set-size-counts clearing": Encoded(SetSizeCountsRequest(surface: surface, lease: "l-1", counts: nil)),
        "detach-attached-view": Encoded(DetachAttachedViewRequest(surface: surface, lease: "l-1")),
        "set-client-sizing claim": Encoded(SetClientSizingRequest(
            surface: surface, enabled: true, exclusive: true, client: ClientID(rawValue: 3)
        )),
        "set-client-sizing release": Encoded(SetClientSizingRequest(surface: surface, enabled: false)),
        "set-size-policy": Encoded(SetSizePolicyRequest(surface: surface, policy: .init(mode: "smallest"))),
        "read-screen": Encoded(ReadScreenRequest(surface: surface)),
        "read-scrollback": Encoded(ReadScrollbackRequest(surface: surface, start: 10, count: 50)),
        "resize-surface": Encoded(ResizeSurfaceRequest(surface: surface, cols: 80, rows: 24)),
        "resize-attached-view": Encoded(ResizeAttachedViewRequest(surface: surface, lease: "l-1", cols: 80, rows: 24)),
        "snapshot-request": Encoded(SnapshotRequestRequest(surface: surface, reason: .digestMismatch)),
    ]

    /// The echo lines: the input the daemon test checks reaches the PTY byte for byte.
    static let echoes: [String: Encoded] = [
        "every byte value": Encoded(SendInputRequest(surface: surface, bytes: Data((0...255).map(UInt8.init)))),
        "control keys": Encoded(SendInputRequest(surface: surface, bytes: Data([0x03, 0x1B, 0x5B, 0x41, 0x0D, 0x7F]))),
        "invalid UTF-8": Encoded(SendInputRequest(surface: surface, bytes: Data([0xFF, 0xFE, 0xC3, 0x28]))),
        "UTF-8 text": Encoded(SendInputRequest(surface: surface, text: "h\u{e9}llo \u{1F30D} \u{4E16}\u{754C}\r")),
        "text then bytes": Encoded(SendInputRequest(surface: surface, text: "ab", bytes: Data([0x1B]))),
        "paste": Encoded(SendInputRequest(surface: surface, text: "echo one\techo two", paste: true)),
    ]

    @Test(arguments: ["requests", "echo"])
    func sendsItsGoldenLines(_ section: String) throws {
        let recorded = try Self.fixture(section)
        let built = section == "echo" ? Self.echoes : Self.requests
        #expect(Set(recorded.keys) == Set(built.keys), "\(section): fixture and test name different requests")
        for (name, golden) in recorded.sorted(by: { $0.key < $1.key }) {
            guard let request = built[name] else { continue }
            let line = try JSONDecoder().decode(JSONValue.self, from: request.encode())
            #expect(line == golden, "\(section) \(name)")
        }
    }

    /// The bytes an echo line carries are the bytes the daemon test expects at the PTY: text, then bytes.
    @Test func everyEchoLineCarriesItsPTYBytes() throws {
        let data = try Self.fixtureData()
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let echoes)? = root["echo"] else {
            Issue.record("lines.json has no echo")
            return
        }
        for case .object(let echo) in echoes {
            guard case .string(let name)? = echo["name"], case .string(let ptyHex)? = echo["pty_hex"],
                  let request = Self.echoes[name],
                  case .object(let line) = try JSONDecoder().decode(JSONValue.self, from: request.encode()) else {
                Issue.record("bad echo entry \(echo)")
                continue
            }
            var bytes = Data()
            if case .string(let text)? = line["text"] { bytes.append(Data(text.utf8)) }
            if case .string(let base64)? = line["bytes"] { bytes.append(try #require(Data(base64Encoded: base64))) }
            #expect(bytes.map { String(format: "%02x", $0) }.joined() == ptyHex, "\(name)")
        }
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, and the
    /// command is one the macOS app calls, so RequestEmitter generates a type with each of these members.
    @Test func sendsOnlySchemaFields() throws {
        let root = try Self.repositoryRoot()
        let schema = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        )
        guard case .object(let document) = schema, case .object(let commands)? = document["commands"] else {
            Issue.record("sdk-schema.json has no commands")
            return
        }
        for section in ["requests", "echo"] {
            for (name, golden) in try Self.fixture(section) {
                guard case .object(let line) = golden, case .string(let command)? = line["cmd"],
                      case .object(let entry)? = commands[command],
                      case .array(let clients)? = entry["clients"], clients.contains(.string("macos")),
                      case .object(let request)? = entry["request"], case .object(let fields)? = request["fields"] else {
                    Issue.record("\(name): not a macos command of sdk-schema.json")
                    continue
                }
                let extra = Set(line.keys).subtracting(["id", "cmd"]).subtracting(fields.keys)
                #expect(extra.isEmpty, "\(name): not schema fields of \(command): \(extra.sorted())")
            }
        }
    }

    // Fixture ---------------------------------------------------------------

    /// `name -> line` of one section of lines.json.
    private static func fixture(_ section: String) throws -> [String: JSONValue] {
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: fixtureData()),
              case .array(let entries)? = root[section] else { return [:] }
        var lines: [String: JSONValue] = [:]
        for case .object(let entry) in entries {
            guard case .string(let name)? = entry["name"], let line = entry["line"] else { continue }
            #expect(lines.updateValue(line, forKey: name) == nil, "\(section): \(name) twice")
        }
        return lines
    }

    private static func fixtureData() throws -> Data {
        try Data(contentsOf: repositoryRoot().appendingPathComponent("cmux-tui/spec/fixtures/terminal-io-requests/lines.json"))
    }

    private static func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        return root
    }
}
