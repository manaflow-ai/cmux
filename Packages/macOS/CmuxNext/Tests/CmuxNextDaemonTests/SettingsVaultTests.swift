import Foundation
import Testing
@testable import CmuxNextDaemon

@MainActor
struct SettingsVaultTests {
    private func object(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

    @Test func stateReadsEntriesAndGrants() async throws {
        var actions: [String] = []
        let vault = SettingsVault(available: { true }, send: { action, _ in
            actions.append(action)
            return action == "list" ? .object(["entries": .array([.object(["name": .string("NODE_ENV")])])])
                : .object(["grants": .array([.object(["id": .string("mac-studio")])])])
        })
        let state = try object(await vault.state())
        #expect(actions == ["list", "grants"])
        #expect(state["unsupported"] == .bool(false))
        #expect(state["entries"]?.arrayValue?.count == 1 && state["grants"]?.arrayValue?.count == 1)
    }

    @Test func daemonWithoutTheCapabilityIsUnsupported() async throws {
        let vault = SettingsVault(available: { true }, send: { _, _ in throw DaemonError.missingCapabilities(["vault-env-v1"]) })
        #expect(try object(await vault.state())["unsupported"] == .bool(true))
    }

    @Test func failedGrantsStillShowEntries() async throws {
        let vault = SettingsVault(available: { true }, send: { action, _ in
            if action == "grants" { throw DaemonError.command(cmd: "vault-env", message: "nope", code: "http_503") }
            return .object(["entries": .array([.object(["name": .string("A")])])])
        })
        let state = try object(await vault.state())
        #expect(state["entries"]?.arrayValue?.count == 1)
        #expect(state["grantsCode"] == .string("http_503"))
        #expect(state["error"] == nil) // the entries read is fine
    }

    @Test func runPassesWritesAndTheRefusalCode() async throws {
        var sent: [String] = []
        let vault = SettingsVault(available: { true }, send: { action, params in
            sent.append(action)
            if params["name"] == .string("OPENAI_API_KEY") {
                throw DaemonError.command(cmd: "vault-env", message: "key-shaped", code: "vault.key_shaped_variable")
            }
            return .object(["name": params["name"] ?? .null, "revision": .number(2)])
        })
        let ok = try object(await vault.run(Data(#"{"action":"rm","params":{"name":"NODE_ENV"}}"#.utf8)))
        #expect(ok["result"]?["revision"] == .number(2))
        let refused = try object(await vault.run(Data(#"{"action":"set","params":{"name":"OPENAI_API_KEY","value":"v","delivery":"env"}}"#.utf8)))
        #expect(refused["code"] == .string("vault.key_shaped_variable"))
        // Reads and unknown actions never go through run.
        let unknown = try object(await vault.run(Data(#"{"action":"list","params":{}}"#.utf8)))
        #expect(unknown["code"] == .string("vault.invalid"))
        #expect(sent == ["rm", "set"])
    }

    @Test func signedOutSendsNothing() async throws {
        var calls = 0
        let vault = SettingsVault(available: { false }, send: { _, _ in calls += 1; return .null })
        #expect(try object(await vault.state())["available"] == .bool(false))
        #expect(try object(await vault.run(Data(#"{"action":"rm","params":{"name":"A"}}"#.utf8)))["code"] == .string("cloud_disabled"))
        #expect(calls == 0)
    }
}
