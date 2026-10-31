import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-lo9yf at the daemon spawn boundary (``AcpmuxHost``): with suggested tasks on (the setting
/// `sessions.promptSuggestions`, on by default, or the Debug Settings toggle `agent.suggestedTasks`
/// forcing them on), the acpmux daemon the app starts has `ACPMUX_OFFER_TOOLS=1`, so every local
/// session gets the cmux-sessions MCP server; off it does not. Both are read at each daemon start,
/// so a change applies to the next daemon this app starts.
@Suite(.serialized)
struct AcpmuxOfferToolsTests {
    /// A short temp root with a stand-in `acpmux` that appends the `ACPMUX_OFFER_TOOLS` it was
    /// started with (or `unset`) to `launches`, then exits before it is ready.
    struct Fixture {
        let root: URL
        let environment: AcpmuxEnvironment
        var launches: [String] {
            ((try? String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        init() throws {
            root = URL(fileURLWithPath: "/tmp/aot-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let acpmux = bin.appendingPathComponent("acpmux")
            let script = "#!/bin/sh\nprintf '%s\\n' \"${ACPMUX_OFFER_TOOLS:-unset}\" >> '\(root.path)/launches'\nexit 1\n"
            try script.write(to: acpmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
            environment = try #require(AcpmuxEnvironment.resolve(
                build: nil, bundledBinDirectory: bin,
                environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path],
                executableOverride: nil
            ))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Debug Settings as the app holds them, with `agent.suggestedTasks` `on` (nil: never set).
    static func tunables(_ on: Bool?) -> TunableStore {
        let store = TunableStore()
        store.register(AgentPaneTunables.all)
        store.activate(file: nil)
        if let on { store.set(AgentPaneTunables.suggestedTasks.key, .bool(on)) }
        return store
    }

    /// The host as the app makes it (``AgentPaneSuggestedTasks/isOn``): the setting, or the toggle
    /// read from `store`, at each daemon start.
    static func host(_ environment: AcpmuxEnvironment, _ store: TunableStore,
                     setting: Bool = SessionSettings.promptSuggestionsDefault) -> AcpmuxHost {
        AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment },
                   offersSessionTools: { setting || AgentPaneTunables.suggestedTasks.value(in: store) })
    }

    @Test func suggestedTasksGiveTheDaemonTheSessionOfferTools() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = Self.host(fixture.environment, Self.tunables(true), setting: false)

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        #expect(fixture.launches == ["1"], "acpmux started without ACPMUX_OFFER_TOOLS=1: \(fixture.launches)")
    }

    /// Suggested tasks are on by default (Leo 2026-10-19).
    @Test func byDefaultTheDaemonGetsTheOfferTools() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = Self.host(fixture.environment, Self.tunables(nil))

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        #expect(fixture.launches == ["1"], "acpmux started without ACPMUX_OFFER_TOOLS=1: \(fixture.launches)")
    }

    @Test func turnedOffTheDaemonGetsNoOfferTools() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = Self.host(fixture.environment, Self.tunables(nil), setting: false)

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        #expect(fixture.launches == ["unset"], "acpmux started with ACPMUX_OFFER_TOOLS: \(fixture.launches)")
    }

    @Test func aToggleAppliesToTheNextDaemonStart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = Self.tunables(nil)
        let host = Self.host(fixture.environment, store, setting: false)

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        store.set(AgentPaneTunables.suggestedTasks.key, .bool(true))
        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        #expect(fixture.launches == ["unset", "1"], "the second daemon start missed the toggle: \(fixture.launches)")
    }
}
