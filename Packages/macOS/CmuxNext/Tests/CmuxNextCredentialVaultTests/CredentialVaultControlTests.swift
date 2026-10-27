import CmuxNextActions
import CmuxNextCompat
import CmuxNextControl
@testable import CmuxNextCredentialVault
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// The Credential Vault over the control socket (`cmux vault …`, cmux issue 26412): the person
/// stores, an agent uses by name within the secret's scope, every use is audited, and no list,
/// index file or audit line ever holds a value.
@MainActor @Suite(.serialized) struct CredentialVaultControlTests {
    /// The Keychain stand-in: values in memory.
    final class MemorySecrets: CredentialVaultSecretStoring, Sendable {
        let values = Mutex([String: String]())
        func save(_ value: String, for name: String) throws { values.withLock { $0[name] = value } }
        func value(for name: String) throws -> String? { values.withLock { $0[name] } }
        func delete(_ name: String) throws { _ = values.withLock { $0.removeValue(forKey: name) } }
    }

    /// The person at the sheet: answers each request with `answer` and records what it was asked.
    final class Person: Sendable {
        let answer: CredentialVault.EntryAnswer?
        let asked = Mutex([CredentialVault.EntryRequest]())
        init(answer: CredentialVault.EntryAnswer?) { self.answer = answer }
    }

    static let secret = "sk-live-0123456789abcdef"
    static let agent: JSONValue = ["agent_session": "sess-1"]
    static let chief: JSONValue = ["home_chat": true]
    static let terminal: JSONValue = ["terminal_id": "term-1"]

    struct Fixture {
        let router: ControlRouter
        let vault: CredentialVault
        let secrets: MemorySecrets
        let person: Person
        let folder: URL
    }

    private func fixture(answer: CredentialVault.EntryAnswer? = nil) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let secrets = MemorySecrets()
        let vault = CredentialVault(secrets: secrets, folder: folder)
        let person = Person(answer: answer)
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: ActionRegistry(catalog: [])), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(vault.controlMethods(ask: { request in
            person.asked.withLock { $0.append(request) }
            return person.answer
        }))
        return Fixture(router: router, vault: vault, secrets: secrets, person: person, folder: folder)
    }

    private func call(_ fixture: Fixture, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await fixture.router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    private func error(_ result: Result<JSONValue, ControlError>) -> ControlError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// Every file the vault wrote, as text: none may hold a value.
    private func files(_ fixture: Fixture) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)
        return try names.map { try String(contentsOf: fixture.folder.appending(path: $0), encoding: .utf8) }.joined(separator: "\n")
    }

    @Test func thePersonStoresAndAnAgentUsesItByNameWithoutAnyRecordHoldingTheValue() async throws {
        let f = try fixture()
        let stored = try await call(f, "vault.set", ["name": "OPENAI_API_KEY", "value": .string(Self.secret), "note": "work",
                                                     "caller": Self.terminal]).get()
        #expect(stored.objectValue?["stored"] == "OPENAI_API_KEY")
        #expect(stored.objectValue?["replaced"] == .bool(false))
        #expect(try f.secrets.value(for: "OPENAI_API_KEY") == Self.secret)

        let list = try await call(f, "vault.list", ["caller": Self.agent]).get()
        let row = try #require(list.objectValue?["secrets"]?.arrayValue?.first?.objectValue)
        #expect(row["name"] == "OPENAI_API_KEY")
        #expect(row["scope"] == .array(["user", "agents"]), "a new secret is for the person and agents")
        #expect(row["note"] == "work")
        #expect(row["uses"] == JSONValue(0))

        let resolved = try await call(f, "vault.resolve", ["names": ["OPENAI_API_KEY"], "command": "/usr/bin/python3 eval.py --key x",
                                                           "caller": Self.agent]).get()
        #expect(resolved.objectValue?["values"]?.objectValue?["OPENAI_API_KEY"] == .string(Self.secret))

        let after = try await call(f, "vault.list", [:]).get()
        let used = try #require(after.objectValue?["secrets"]?.arrayValue?.first?.objectValue)
        #expect(used["uses"] == JSONValue(1))
        #expect(used["last_used_by"] == "agent session sess-1")

        let audit = try await call(f, "vault.audit", [:]).get()
        let records = try #require(audit.objectValue?["records"]?.arrayValue)
        #expect(records.map { $0.objectValue?["outcome"] } == ["stored", "granted"])
        #expect(records.last?.objectValue?["command"] == "python3", "only the program, never its arguments")
        #expect(records.last?.objectValue?["consumer"] == "agents")

        for text in ["\(list)", "\(after)", "\(audit)", try files(f)] {
            #expect(!text.contains(Self.secret), "a value leaked: \(text)")
        }
    }

    @Test func onlyThePersonAddsChangesOrRemovesSecrets() async throws {
        let f = try fixture()
        for caller in [Self.agent, Self.chief] {
            let set = await call(f, "vault.set", ["name": "GH_TOKEN", "value": "ghp_agent-chosen-value", "caller": caller])
            #expect(error(set)?.code == "vault.user_only", "\(set)")
        }
        #expect(try f.secrets.value(for: "GH_TOKEN") == nil)
        _ = try await call(f, "vault.set", ["name": "GH_TOKEN", "value": "ghp_person-value-123"]).get()
        let remove = await call(f, "vault.remove", ["name": "GH_TOKEN", "caller": Self.agent])
        #expect(error(remove)?.code == "vault.user_only")
        let scope = await call(f, "vault.scope", ["name": "GH_TOKEN", "scope": "agents", "caller": Self.agent])
        #expect(error(scope)?.code == "vault.user_only")
        #expect(try f.secrets.value(for: "GH_TOKEN") == "ghp_person-value-123")

        let removed = try await call(f, "vault.remove", ["name": "GH_TOKEN"]).get()
        #expect(removed.objectValue?["existed"] == .bool(true))
        #expect(try f.secrets.value(for: "GH_TOKEN") == nil)
    }

    @Test func aSecretKeptForThePersonIsRefusedToAgentsAndTheRefusalIsAudited() async throws {
        let f = try fixture()
        _ = try await call(f, "vault.set", ["name": "PROD_DB", "value": "postgres://prod-secret", "scope": ["user"]]).get()
        _ = try await call(f, "vault.set", ["name": "GH_TOKEN", "value": "ghp_person-value-123"]).get()

        for caller in [Self.agent, Self.chief] {
            let denied = await call(f, "vault.resolve", ["names": ["GH_TOKEN", "PROD_DB"], "command": "psql", "caller": caller])
            #expect(error(denied)?.code == "vault.denied", "\(denied)")
            #expect(error(denied)?.data?.objectValue?["names"] == .array(["PROD_DB"]))
            #expect(!"\(denied)".contains("ghp_person-value-123"), "all or none: no value of an allowed name either")
        }
        let mine = try await call(f, "vault.resolve", ["names": ["PROD_DB"], "caller": Self.terminal]).get()
        #expect(mine.objectValue?["values"]?.objectValue?["PROD_DB"] == "postgres://prod-secret")

        let missing = await call(f, "vault.resolve", ["names": ["NOPE"], "caller": Self.terminal])
        #expect(error(missing)?.code == "vault.missing")

        let records = try await call(f, "vault.audit", [:]).get().objectValue?["records"]?.arrayValue ?? []
        #expect(records.compactMap { $0.objectValue?["outcome"]?.stringValue }.suffix(4) == ["denied", "denied", "granted", "missing"])

        _ = try await call(f, "vault.scope", ["name": "PROD_DB", "scope": "user,agents"]).get()
        let allowed = try await call(f, "vault.resolve", ["names": ["PROD_DB"], "caller": Self.agent]).get()
        #expect(allowed.objectValue?["values"]?.objectValue?["PROD_DB"] == "postgres://prod-secret")
    }

    @Test func theChiefAsksThePersonOnTheSheetAndNeverHearsTheValue() async throws {
        let f = try fixture(answer: CredentialVault.EntryAnswer(value: Self.secret, scope: [.user, .agents]))
        let answer = try await call(f, "vault.request", ["name": "OPENAI_API_KEY", "reason": "run the eval", "caller": Self.chief]).get()
        #expect(answer.objectValue?["stored"] == "OPENAI_API_KEY")
        #expect(!"\(answer)".contains(Self.secret))
        let asked = f.person.asked.withLock { $0 }
        #expect(asked == [CredentialVault.EntryRequest(name: "OPENAI_API_KEY", reason: "run the eval", requester: "the Chief", replaces: false)])
        #expect(try f.secrets.value(for: "OPENAI_API_KEY") == Self.secret)
        let row = try await call(f, "vault.list", [:]).get().objectValue?["secrets"]?.arrayValue?.first?.objectValue
        #expect(row?["note"] == "run the eval")
        let record = try await call(f, "vault.audit", [:]).get().objectValue?["records"]?.arrayValue?.last?.objectValue
        #expect(record?["event"] == "request")
        #expect(record?["by"] == "you, asked by the Chief")
        #expect(record?["consumer"] == "user")
    }

    @Test func aDeclinedRequestStoresNothing() async throws {
        let f = try fixture(answer: nil)
        let declined = await call(f, "vault.request", ["name": "GH_TOKEN", "caller": Self.agent])
        #expect(error(declined)?.code == "declined")
        #expect(try f.secrets.value(for: "GH_TOKEN") == nil)
        let bad = await call(f, "vault.request", ["name": "not a name", "caller": Self.agent])
        #expect(error(bad)?.code == "invalid_params")
        #expect(f.person.asked.withLock { $0.count } == 1, "an invalid name never reaches the person")
    }

    @Test func theSheetHidesTheValueAndItsAnswerCarriesTheScope() {
        let spec = CredentialVault.entrySheet(.init(name: "GH_TOKEN", reason: "open the PR", requester: "the Chief", replaces: false))
        #expect(spec.identifier == CredentialVault.entrySheetIdentifier)
        #expect(spec.fields.contains(.text(id: CredentialVault.entryValueField, label: CredentialVaultStrings.entryValueLabel, initial: "", placeholder: nil, secure: true)))
        let field = CredentialVault.entryValueField, agents = CredentialVault.entryAgentsField, save = CredentialVault.entrySaveButton
        let saved = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("ghp_x1234"), agents: .bool(false)])
        #expect(CredentialVault.entryAnswer(saved) == .init(value: "ghp_x1234", scope: [.user]))
        let both = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("ghp_x1234"), agents: .bool(true)])
        #expect(CredentialVault.entryAnswer(both) == .init(value: "ghp_x1234", scope: [.user, .agents]))
        let empty = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("")])
        #expect(CredentialVault.entryAnswer(empty) == nil)
        let cancelled = CmuxDialogAnswer(button: "cancel", role: .cancel, values: [field: .text("ghp_x1234")])
        #expect(CredentialVault.entryAnswer(cancelled) == nil)
        let closed = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("ghp_x1234")], isDismissal: true)
        #expect(CredentialVault.entryAnswer(closed) == nil)
    }
}
