import Foundation
import Testing
@testable import CmuxMobileChief

/// Settings → Cloud → Vault's model over a scripted ``VaultService``: what each state reads as, that
/// a change seals to the machines (``VaultTriggers``) and a failure says why without a value, and
/// that the account's vault path reaches only `/v1/cloud/vault`.
@MainActor
@Suite(.serialized) struct VaultModelTests {
    final class Script: VaultService, @unchecked Sendable {
        var statusJSON: String
        var failSet: VaultFailure?
        var setCalls: [(name: String, scope: String)] = []
        var approved: [String] = []

        init(_ state: String) { statusJSON = GalleryVaultService(state: state).json }

        func status() async throws -> String { statusJSON }
        func turnOn() async throws -> String {
            statusJSON = GalleryVaultService(state: "pending").json
            return statusJSON
        }
        func approve(code: String) async throws { approved.append(code) }
        func removeDevice(id: String) async throws {}
        func set(name: String, scope: String, value: String) async throws {
            if let failSet { throw failSet }
            setCalls.append((name, scope))
        }
        func remove(name: String, scope: String) async throws {}
        func importPreview(envText: String, scope: String) async throws -> String {
            #"{"rows":[{"name":"A","line":1,"keepable":true,"alreadyKept":false,"masked":"••••••••"},{"name":"PATH","line":2,"keepable":false,"alreadyKept":false,"masked":"••••••••"}],"skippedLines":[4]}"#
        }
        func importNames(envText: String, names: [String], scope: String) async throws -> Int { names.count }
        func sync() async throws -> String { #"{"outcome":"done","machines":[]}"# }
        func scope(kind: VaultScopeKind, target: String) -> String? { GalleryVaultService(state: "off").scope(kind: kind, target: target) }
        func isValidName(_ name: String) -> Bool { name != "PATH" }
    }

    @Test func offTurnsOnIntoPendingWithThisPhonesCode() async {
        let script = Script("off")
        let model = VaultModel(service: script)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.state == "off")
        await model.turnOn()
        #expect(model.state == "pending")
        #expect(model.status?.safetyCode == "4821 0937")
    }

    @Test func onListsNamesMaskedAndThisPhoneFirst() async {
        let model = VaultModel(service: Script("on"))
        await model.load()
        #expect(model.state == "active")
        #expect(model.items.map(\.name) == ["ANTHROPIC_API_KEY", "DATABASE_URL", "GITHUB_TOKEN", "STRIPE_SECRET_KEY"])
        #expect(model.items.allSatisfy { $0.masked == "••••••••" })
        #expect(model.devices.first?.thisDevice == true)
        #expect(model.devices.last?.state == "pending")
    }

    @Test func aChangeSealsToTheMachinesAndApproveUsesTheListedCode() async {
        var reasons: [VaultTriggers.Reason] = []
        VaultTriggers.run = { reasons.append($0) }
        defer { VaultTriggers.run = nil }
        let script = Script("on")
        let model = VaultModel(service: script)
        await model.load()
        #expect(await model.set(name: "OPENAI_API_KEY", scope: "*", value: "sk-secret"))
        #expect(script.setCalls.map(\.name) == ["OPENAI_API_KEY"])
        #expect(reasons == [.changed])
        let waiting = model.devices.first { $0.state == "pending" }!  // crash-allow: test fixture has one
        await model.approve(waiting)
        #expect(script.approved == ["7703 1149"])
        #expect(reasons == [.changed], "approving a device seals nothing to machines")
    }

    @Test func aRefusalSaysWhyAndSealsNothing() async {
        var reasons: [VaultTriggers.Reason] = []
        VaultTriggers.run = { reasons.append($0) }
        defer { VaultTriggers.run = nil }
        let script = Script("on")
        script.failSet = .refused(code: "vault.bad_name", message: "PATH is not a name the vault keeps")
        let model = VaultModel(service: script)
        await model.load()
        #expect(await model.set(name: "PATH", scope: "*", value: "sk-secret") == false)
        #expect(model.failure == "PATH is not a name the vault keeps")
        #expect(model.failure?.contains("sk-secret") == false)
        #expect(reasons.isEmpty)
    }

    @Test func anImportPreviewIsNamesOnly() async {
        let model = VaultModel(service: Script("on"))
        let preview = await model.preview(envText: "A=sk-secret\nPATH=/bin\n", scope: "*")
        #expect(preview?.rows.map(\.name) == ["A", "PATH"])
        #expect(preview?.rows.last?.keepable == false)
        #expect(preview?.skippedLines == [4])
    }

    @Test func theVaultPathReachesOnlyTheVaultRoutes() {
        #expect(AccountCloud.isVaultPath("/v1/cloud/vault"))
        #expect(AccountCloud.isVaultPath("/v1/cloud/vault?vault=personal"))
        #expect(AccountCloud.isVaultPath("/v1/cloud/vault/items/abc?vault=personal&expectedRevision=3"))
        #expect(!AccountCloud.isVaultPath("/v1/cloud/vaultx"))
        #expect(!AccountCloud.isVaultPath("/v1/cloud/vault/../machines"))
        #expect(!AccountCloud.isVaultPath("/v1/cloud/vault/%2E%2E/ops"))
        #expect(!AccountCloud.isVaultPath("/v1/ops"))
        #expect(AccountCloud.isVaultDevice("dev_AbC-_9"))
        #expect(!AccountCloud.isVaultDevice("dev_x\r\nx-evil: 1"))
        #expect(!AccountCloud.isVaultDevice("machine"))
    }
}
