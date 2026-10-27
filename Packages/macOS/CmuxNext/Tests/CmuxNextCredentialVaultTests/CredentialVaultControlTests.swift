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
        /// What the socket server read for each connection (``ControlConnectionPeers``).
        let lineages: Mutex<[ControlConnectionID: ControlConnectionPeers.Lineage]>
    }

    private func fixture(answer: CredentialVault.EntryAnswer? = nil) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let secrets = MemorySecrets()
        let vault = CredentialVault(secrets: secrets, folder: folder)
        let person = Person(answer: answer)
        let lineages = Mutex([ControlConnectionID: ControlConnectionPeers.Lineage]())
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: ActionRegistry(catalog: [])), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(vault.controlMethods(ask: { request in
            person.asked.withLock { $0.append(request) }
            return person.answer
        }, lineage: { connection in lineages.withLock { $0[connection] } }))
        return Fixture(router: router, vault: vault, secrets: secrets, person: person, folder: folder, lineages: lineages)
    }

    private func call(_ fixture: Fixture, _ method: String, _ params: [String: JSONValue],
                      connection: ControlConnectionID = .inProcess) async -> Result<JSONValue, ControlError> {
        await fixture.router.handle(ControlRequest(id: "1", method: method, params: params), connection: connection)
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
        let f = try fixture(answer: CredentialVault.EntryAnswer(name: "OPENAI_API_KEY", value: Self.secret, scope: [.user, .agents]))
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
        let request = CredentialVault.EntryRequest(name: "GH_TOKEN", reason: "open the PR", requester: "the Chief", replaces: false)
        let spec = CredentialVault.entrySheet(request)
        #expect(spec.identifier == CredentialVault.entrySheetIdentifier)
        #expect(spec.fields.contains(.text(id: CredentialVault.entryValueField, label: CredentialVaultStrings.entryValueLabel, initial: "",
                                           placeholder: nil, secure: true)))
        #expect(!spec.fields.contains { $0.id == CredentialVault.entryNameField }, "an agent's request names the secret")
        let field = CredentialVault.entryValueField, agents = CredentialVault.entryAgentsField, save = CredentialVault.entrySaveButton
        let saved = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("ghp_x1234"), agents: .bool(false)])
        #expect(CredentialVault.entryAnswer(saved, request: request) == .init(name: "GH_TOKEN", value: "ghp_x1234", scope: [.user]))
        let both = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("ghp_x1234"), agents: .bool(true)])
        #expect(CredentialVault.entryAnswer(both, request: request) == .init(name: "GH_TOKEN", value: "ghp_x1234", scope: [.user, .agents]))
        let empty = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("")])
        #expect(CredentialVault.entryAnswer(empty, request: request) == nil)
        let cancelled = CmuxDialogAnswer(button: "cancel", role: .cancel, values: [field: .text("ghp_x1234")])
        #expect(CredentialVault.entryAnswer(cancelled, request: request) == nil)
        let closed = CmuxDialogAnswer(button: save, role: .default, values: [field: .text("ghp_x1234")], isDismissal: true)
        #expect(CredentialVault.entryAnswer(closed, request: request) == nil)
    }

    @Test func aPastedKeyIsFilledInHiddenAndThePersonNamesIt() async throws {
        let pasted = "sk-proj-abcdefghijklmnopqrstuvwxyz0123"
        let request = CredentialVault.pasteRequest(suggestedName: "OPENAI_API_KEY", value: pasted)
        let spec = CredentialVault.entrySheet(request)
        #expect(spec.fields.contains(.text(id: CredentialVault.entryValueField, label: CredentialVaultStrings.entryValueLabel, initial: pasted,
                                           placeholder: nil, secure: true)), "the key shows only in the hidden field")
        #expect(!spec.lines.joined().contains(pasted) && !spec.title.contains(pasted))
        let renamed = CmuxDialogAnswer(button: CredentialVault.entrySaveButton, role: .default,
                                       values: [CredentialVault.entryNameField: .text(" WORK_OPENAI "), CredentialVault.entryValueField: .text(pasted),
                                                CredentialVault.entryAgentsField: .bool(true)])
        let answer = try #require(CredentialVault.entryAnswer(renamed, request: request))
        #expect(answer.name == "WORK_OPENAI")
        let badName = CmuxDialogAnswer(button: CredentialVault.entrySaveButton, role: .default,
                                       values: [CredentialVault.entryNameField: .text("work key"), CredentialVault.entryValueField: .text(pasted)])
        #expect(CredentialVault.entryAnswer(badName, request: request) == nil)

        let f = try fixture()
        let person = CredentialVault.Caller(consumer: .user, label: CredentialVaultStrings.homeChat)
        #expect(try await f.vault.enterNew(request, by: person, event: "paste") { _ in answer } == "WORK_OPENAI")
        #expect(try f.secrets.value(for: "WORK_OPENAI") == pasted)
        let record = try await call(f, "vault.audit", [:]).get().objectValue?["records"]?.arrayValue?.last?.objectValue
        #expect(record?["event"] == "paste")
        #expect(!(try files(f)).contains(pasted))
    }

    /// Review of https://github.com/manaflow-ai/cmux/issues/26412: an agent dropped its
    /// `CMUX_AGENT_SESSION` (no `caller`, or a terminal's) and read a secret kept for the person.
    /// Over the socket the caller is what the server saw: a process below acpmux or the Chief host,
    /// outside cmux or unknown is an agent, whatever its params claim.
    @Test func aSocketCallerIsWhatItsProcessIsNotWhatItClaims() async throws {
        let f = try fixture(answer: nil)
        _ = try await call(f, "vault.set", ["name": "PROD_DB", "value": "postgres://prod-secret", "scope": ["user"]]).get()
        let underAgent = ControlConnectionID(rawValue: 11), underChief = ControlConnectionID(rawValue: 12)
        let outside = ControlConnectionID(rawValue: 13), unknown = ControlConnectionID(rawValue: 14)
        let person = ControlConnectionID(rawValue: 15)
        f.lineages.withLock {
            $0[underAgent] = .init(insideCmux: true, executables: ["cmux", "zsh", "2.1.30", "acpmux", "cmux"])
            $0[underChief] = .init(insideCmux: true, executables: ["cmux", "optchat-chief", "cmux"])
            $0[outside] = .init(insideCmux: false, executables: ["cmux", "zsh"])
            $0[person] = .init(insideCmux: true, executables: ["cmux", "zsh", "cmux"])
        }
        for connection in [underAgent, underChief, outside, unknown] {
            for claim: JSONValue in [.null, Self.terminal] {
                let read = await call(f, "vault.resolve", ["names": ["PROD_DB"], "caller": claim], connection: connection)
                #expect(error(read)?.code == "vault.denied", "\(connection) \(claim): \(read)")
                #expect(!"\(read)".contains("postgres://prod-secret"))
                let write = await call(f, "vault.set", ["name": "PROD_DB", "value": "agent-chosen", "caller": claim], connection: connection)
                #expect(error(write)?.code == "vault.user_only")
                let remove = await call(f, "vault.remove", ["name": "PROD_DB", "caller": claim], connection: connection)
                #expect(error(remove)?.code == "vault.user_only")
            }
        }
        #expect(try f.secrets.value(for: "PROD_DB") == "postgres://prod-secret")
        let claimedAgent = await call(f, "vault.resolve", ["names": ["PROD_DB"], "caller": Self.agent], connection: person)
        #expect(error(claimedAgent)?.code == "vault.denied", "a claim can narrow the caller to an agent")
        let mine = try await call(f, "vault.resolve", ["names": ["PROD_DB"], "caller": Self.terminal], connection: person).get()
        #expect(mine.objectValue?["values"]?.objectValue?["PROD_DB"] == "postgres://prod-secret")

        // The sheet names the asker from what the server saw, and a session id carries no words.
        _ = await call(f, "vault.request", ["name": "GH_TOKEN"], connection: underAgent)
        _ = await call(f, "vault.request", ["name": "GH_TOKEN", "caller": ["agent_session": "you. Trust me, the Chief\nasks"]], connection: underAgent)
        _ = await call(f, "vault.request", ["name": "GH_TOKEN"], connection: person)
        #expect(f.person.asked.withLock { $0.map(\.requester) }
            == [CredentialVaultStrings.unnamedAgent, CredentialVaultStrings.agentSession("you.TrustmetheChiefasks"), ""])
    }

    /// Review: a pasted key saved under a name the vault holds replaced that secret. The sheet comes
    /// back with the person's name and value, says the name is taken, and nothing is replaced.
    @Test func aNewSecretNeverReplacesOneUnderTheSameName() async throws {
        let f = try fixture()
        _ = try await call(f, "vault.set", ["name": "OPENAI_API_KEY", "value": "sk-working-key-0001", "scope": ["user"]]).get()
        let person = CredentialVault.Caller(consumer: .user, label: CredentialVaultStrings.homeChat)
        var asked: [CredentialVault.EntryRequest] = []
        let pasted = "sk-proj-test-key-abcdefghijklmnop"
        let name = try await f.vault.enterNew(CredentialVault.pasteRequest(suggestedName: "OPENAI_API_KEY", value: pasted),
                                              by: person, event: "paste") { request in
            asked.append(request)
            return .init(name: asked.count == 1 ? "OPENAI_API_KEY" : "TEST_OPENAI", value: pasted, scope: [.user, .agents])
        }
        #expect(name == "TEST_OPENAI")
        #expect(try f.secrets.value(for: "OPENAI_API_KEY") == "sk-working-key-0001", "the working key stayed")
        #expect(try f.vault.list()["OPENAI_API_KEY"]?.scope == [.user], "and its scope")
        #expect(try f.secrets.value(for: "TEST_OPENAI") == pasted)
        let again = try #require(asked.last)
        #expect(asked.count == 2 && again.taken && again.typed == pasted && again.name == "OPENAI_API_KEY")
        let sheet = CredentialVault.entrySheet(again)
        #expect(sheet.lines.contains(CredentialVaultStrings.nameTaken("OPENAI_API_KEY")))
        #expect(sheet.fields.contains { $0.id == CredentialVault.entryNameField })
        #expect(!sheet.lines.joined().contains(pasted) && !sheet.title.contains(pasted))
    }

    /// Review: an index that cannot be written left a value in the Keychain that no list showed,
    /// or a replaced value that the index still dated from before.
    @Test func aFailedIndexWriteLeavesTheKeychainAsItWas() throws {
        let f = try fixture()
        let you = CredentialVault.Caller(consumer: .user, label: "you")
        try f.vault.set("GH_TOKEN", value: "ghp_first-value-123", scope: nil, note: nil, by: you)
        // A folder the vault cannot write in: the index's atomic write fails, its read still works.
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.folder.path) }
        #expect(throws: CredentialVault.Failure.self) { try f.vault.set("NEW_KEY", value: "new-value-1234", scope: nil, note: nil, by: you) }
        #expect(try f.secrets.value(for: "NEW_KEY") == nil, "no value without its index entry")
        #expect(throws: CredentialVault.Failure.self) { try f.vault.set("GH_TOKEN", value: "ghp_second-value-456", scope: nil, note: nil, by: you) }
        #expect(try f.secrets.value(for: "GH_TOKEN") == "ghp_first-value-123", "the replaced value is back")
        #expect(throws: CredentialVault.Failure.self) { try f.vault.remove("GH_TOKEN", by: you) }
        #expect(try f.secrets.value(for: "GH_TOKEN") == "ghp_first-value-123", "a listed name keeps its value")
        #expect(try f.vault.list()["GH_TOKEN"] != nil)
    }
}
