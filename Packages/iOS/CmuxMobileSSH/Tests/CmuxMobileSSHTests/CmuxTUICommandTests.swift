@testable import CmuxMobileSSH
import Foundation
import Testing

/// The iOS client's command table (`CmuxTUICommand`) against the daemon's schema: every case is a
/// schema command marked `clients: ios`, and every `clients: ios` command is a case, so the schema
/// meta that assign-ipc-method-ids.py writes from this table cannot drift from what the phone sends.
@Suite struct CmuxTUICommandTests {
    /// The repository's `cmux-tui/spec/sdk-schema.json`: the nearest directory above this file
    /// that holds `cmux-tui/spec`, the way the CmuxNext schema goldens find it.
    private static func schemaCommands() throws -> [String: [String: Any]] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above the test")
            root = parent
        }
        let data = try Data(contentsOf: root.appending(path: "cmux-tui/spec/sdk-schema.json"))
        let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(schema["commands"] as? [String: [String: Any]])
    }

    @Test func everyCommandIsMarkedForIOSInTheSchema() throws {
        let commands = try Self.schemaCommands()
        // An absent `clients` means every client (spec/transports.md).
        let marked = Set(commands.keys.filter { name in
            (commands[name]?["clients"] as? [String])?.contains("ios") ?? true
        })
        #expect(Set(CmuxTUICommand.allCases.map(\.rawValue)) == marked)
    }

    /// Golden: a navigation sends the wire name its public raw value always spelled.
    @Test func browserNavigationKeepsItsWireNames() async throws {
        for navigation in [CmuxTUIBrowserNavigation.back, .forward, .reload] {
            #expect(navigation.command.rawValue == navigation.rawValue)
            let peer = ScriptedCmuxTUIPeer()
            let control = try await peer.open(requestedSession: "main", reportedSession: "main")
            async let sent: Void = control.browser(navigation, surface: 3)
            let request = try await peer.nextRequest()
            #expect(request["cmd"] as? String == navigation.rawValue)
            #expect(request["surface"] as? Int == 3)
            #expect(Set(request.keys) == ["id", "cmd", "surface"])
            peer.reply(#"{"id":"\#(request["id"] as! String)","ok":true,"data":{}}"#)
            try await sent
            await control.close()
        }
    }
}
