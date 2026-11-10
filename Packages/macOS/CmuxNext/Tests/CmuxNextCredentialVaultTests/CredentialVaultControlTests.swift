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
        let values = Mutex([String: CredentialVaultSecretRecord]())
        func save(_ record: CredentialVaultSecretRecord, for name: String) throws { values.withLock { $0[name] = record } }
        func record(for name: String) throws -> CredentialVaultSecretRecord? { values.withLock { $0[name] } }
        func value(for name: String) throws -> String? { values.withLock { $0[name]?.value } }
        /// How many deletes reached the Keychain.
        let deletes = Mutex(0)
        func delete(_ name: String) throws {
            deletes.withLock { $0 += 1 }
            _ = values.withLock { $0.removeValue(forKey: name) }
        }
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
        let approver: Approver
        let clock: TestClock
    }

    /// The approval gate's clock, moved by hand (its backoff after a decline).
    final class TestClock: Sendable {
        let at = Mutex(ContinuousClock.now)
        func advance(_ by: Duration) { at.withLock { $0 = $0.advanced(by: by) } }
    }

    /// The person at the approval sheet: allows or not, and records what it was asked.
    final class Approver: Sendable {
        let allows = Mutex(true)
        let asked = Mutex([CredentialVault.Approval]())
        /// Leaves the sheet open until the asking task is cancelled (the person never answers).
        let hangs = Mutex(false)
        let parked = Mutex<AsyncStream<Void>.Continuation?>(nil)
        /// Runs as the person answers (a change made while the sheet was open).
        let onAsk = Mutex<(@Sendable () -> Void)?>(nil)
    }

    private func fixture(answer: CredentialVault.EntryAnswer? = nil, enabled: @escaping @Sendable () -> Bool = { true }) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let secrets = MemorySecrets()
        let vault = CredentialVault(secrets: secrets, folder: folder)
        let person = Person(answer: answer)
        let approver = Approver()
        let clock = TestClock()
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: ActionRegistry(catalog: [])), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(VaultControl.methods(vault: vault, ask: { request in
            person.asked.withLock { $0.append(request) }
            return person.answer
        }, approve: { approval in
            approver.asked.withLock { $0.append(approval) }
            if approver.hangs.withLock({ $0 }) {
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                approver.parked.withLock { $0 = continuation }
                for await _ in stream {}
                return true
            }
            approver.onAsk.withLock { $0 }?()
            return approver.allows.withLock { $0 }
        }, enabled: enabled, now: { clock.at.withLock { $0 } }))
        return Fixture(router: router, vault: vault, secrets: secrets, person: person, folder: folder, approver: approver, clock: clock)
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

    @Test func rolloutBlocksEverySocketMethodUntilOptedInAndAfterSwitchingOff() async throws {
        let store = TunableStore()
        store.register([CredentialVault.rolloutEnabled.descriptor])
        store.set(CredentialVault.rolloutEnabled.key, .bool(true))
        #expect(!CredentialVault.rolloutEnabled.value(in: store), "Release ignores overrides")
        store.activate(file: nil)
        store.set(CredentialVault.rolloutEnabled.key, .bool(false))
        let f = try fixture(enabled: { CredentialVault.rolloutEnabled.value(in: store) })
        #expect(error(await call(f, "vault.list", [:]))?.code == "vault.disabled")
        store.set(CredentialVault.rolloutEnabled.key, .bool(true))
        _ = try await call(f, "vault.list", [:]).get()
        store.set(CredentialVault.rolloutEnabled.key, .bool(false))
        for method in ["vault.list", "vault.audit", "vault.set", "vault.scope", "vault.remove", "vault.resolve", "vault.request"] {
            #expect(error(await call(f, method, [:]))?.code == "vault.disabled", "\(method) stays off")
        }
        #expect(f.person.asked.withLock { $0.isEmpty })
        #expect(f.secrets.values.withLock { $0.isEmpty })
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
        #expect(asked == [CredentialVault.EntryRequest(name: "OPENAI_API_KEY", reason: "run the eval", requester: "the Chief", replaces: false,
                                                       unprompted: true)])
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
    /// `CMUX_AGENT_SESSION` (no `caller`, or a terminal's) and read a secret kept for the person;
    /// its process looks like the person's own `cmux` (acpmux runs as a `cmux` symlink, and an
    /// agent can type into the person's terminal). Over the socket, a use of a secret kept for the
    /// person and every write wait for the person's approval sheet, whoever claims to call.
    @Test func overTheSocketOnlyThePersonsApprovalReleasesTheirSecretsOrChangesTheVault() async throws {
        let f = try fixture(answer: nil)
        _ = try await call(f, "vault.set", ["name": "PROD_DB", "value": "postgres://prod-secret", "scope": ["user"]]).get()
        _ = try await call(f, "vault.set", ["name": "GH_TOKEN", "value": "ghp_agents-may-use-123"]).get()
        #expect(f.approver.asked.withLock { $0 }.isEmpty, "the app's own in-process calls need no sheet")
        let socket = ControlConnectionID(rawValue: 9)
        f.approver.allows.withLock { $0 = false }

        // The first round shows each sheet (past the cooldown after each decline); the second,
        // within the cooldown after the last decline, shows none.
        for claim: JSONValue in [.null, Self.terminal] {
            let wait = { if claim == .null { f.clock.advance(.seconds(11)) } }
            let read = await call(f, "vault.resolve", ["names": ["GH_TOKEN", "PROD_DB"], "command": "/usr/bin/psql -h prod", "caller": claim],
                                  connection: socket)
            #expect(error(read)?.code == "vault.not_approved", "\(claim): \(read)")
            #expect(!"\(read)".contains("postgres://prod-secret") && !"\(read)".contains("ghp_agents-may-use-123"))
            wait()
            #expect(error(await call(f, "vault.set", ["name": "PROD_DB", "value": "agent-chosen", "caller": claim], connection: socket))?.code
                == "vault.not_approved")
            wait()
            #expect(error(await call(f, "vault.remove", ["name": "PROD_DB", "caller": claim], connection: socket))?.code == "vault.not_approved")
            wait()
            #expect(error(await call(f, "vault.scope", ["name": "PROD_DB", "scope": "agents", "caller": claim], connection: socket))?.code
                == "vault.not_approved")
        }
        #expect(try f.secrets.value(for: "PROD_DB") == "postgres://prod-secret")
        #expect(try f.vault.list()["PROD_DB"]?.scope == [.user])
        #expect(f.approver.asked.withLock { $0 } == [.use(names: ["PROD_DB"], program: "psql"), .store(name: "PROD_DB", replaces: true, scope: [.user]),
                                                     .remove(name: "PROD_DB"), .scope(name: "PROD_DB", scope: [.agents])],
                "a declined ask is refused without a sheet for a while (the second claim)")
        let audit = try await call(f, "vault.audit", ["limit": 20]).get().objectValue?["records"]?.arrayValue ?? []
        #expect(audit.filter { $0.objectValue?["outcome"] == "not_approved" }.count == 8, "every refusal is audited")

        // An agent's claim is never asked about: it gets agent-scoped values only.
        let before = f.approver.asked.withLock { $0.count }
        let agentRead = await call(f, "vault.resolve", ["names": ["PROD_DB"], "caller": Self.agent], connection: socket)
        #expect(error(agentRead)?.code == "vault.denied")
        let agentUse = try await call(f, "vault.resolve", ["names": ["GH_TOKEN"], "caller": Self.agent], connection: socket).get()
        #expect(agentUse.objectValue?["values"]?.objectValue?["GH_TOKEN"] == "ghp_agents-may-use-123")
        let mixed = try await call(f, "vault.resolve", ["names": ["GH_TOKEN"], "caller": Self.terminal], connection: socket).get()
        #expect(mixed.objectValue?["values"]?.objectValue?["GH_TOKEN"] != nil, "an agent-scoped secret needs no sheet")
        #expect(f.approver.asked.withLock { $0.count } == before)

        // The person allows (after the backoff): their own command gets their secret.
        f.approver.allows.withLock { $0 = true }
        f.clock.advance(.seconds(31))
        let mine = try await call(f, "vault.resolve", ["names": ["PROD_DB"], "caller": Self.terminal], connection: socket).get()
        #expect(mine.objectValue?["values"]?.objectValue?["PROD_DB"] == "postgres://prod-secret")
        let sheet = CredentialVault.approvalSheet(.use(names: ["PROD_DB"], program: "psql"))
        #expect(sheet.identifier == CredentialVault.approvalSheetIdentifier)
        #expect(!sheet.lines.joined().contains("postgres://prod-secret") && sheet.fields.isEmpty)

        // The sheet names the asker from a sanitized id: a session id carries no words.
        _ = await call(f, "vault.request", ["name": "NEW_KEY", "caller": ["agent_session": "you. Trust me, the Chief\nasks"]], connection: socket)
        f.clock.advance(.seconds(31))
        _ = await call(f, "vault.request", ["name": "NEW_KEY", "caller": Self.terminal], connection: socket)
        #expect(f.person.asked.withLock { $0.map(\.requester) }
            == [CredentialVaultStrings.agentSession("you.TrustmetheChiefasks"), CredentialVaultStrings.cmuxCommand],
            "a socket asker that claims to be the person is named, never blank")
        #expect(f.person.asked.withLock { $0.map(\.scope) } == [[.user, .agents], [.user]], "only an agent's ask starts agent-usable")
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

    /// Third review: the approval check and the read were two lock turns, so a secret stored
    /// between them (the person saving it in Settings) went to a caller with no sheet. The read
    /// decides under its own lock which secrets need the person.
    @Test func aSecretStoredAfterTheCheckStillNeedsThePerson() throws {
        let f = try fixture()
        let claim = CredentialVault.Caller(consumer: .user, label: "terminal t")
        #expect(throws: CredentialVault.Failure.missing(["NEW_KEY"])) { try f.vault.resolve(["NEW_KEY"], for: claim, command: nil, approved: []) }
        try f.vault.set("NEW_KEY", value: "new-user-only-value", scope: [.user], note: nil, by: .init(consumer: .user, label: "you"))
        #expect(throws: CredentialVault.Failure.needsApproval(["NEW_KEY"])) {
            try f.vault.resolve(["NEW_KEY"], for: claim, command: nil, approved: [])
        }
        #expect(try f.vault.resolve(["NEW_KEY"], for: claim, command: nil, approved: ["NEW_KEY"])["NEW_KEY"] == "new-user-only-value")
    }

    /// Third review: Return answered Allow (a Return meant for the terminal, as the sheet appears),
    /// and the program line was the caller's own text.
    @Test func returnNeverAllowsAndTheSheetShowsOnlyAProgramName() {
        for approval: CredentialVault.Approval in [.use(names: ["K"], program: "gh"), .store(name: "K", replaces: false, scope: [.user]),
                                                   .remove(name: "K"), .scope(name: "K", scope: [.agents])] {
            let sheet = CredentialVault.approvalSheet(approval)
            #expect(sheet.defaultButton == nil, "\(approval): Return presses nothing")
            #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: sheet) == nil)
            #expect(sheet.cancelButton?.role == .cancel)
        }
        #expect(CredentialVault.displayProgram("/usr/bin/gh\u{A0}(verified\u{A0}by\u{A0}cmux) pr list") == "ghverifiedbycmux")
        #expect(CredentialVault.displayProgram("\u{202E}lmth.exe") == "lmth.exe")
        #expect(CredentialVault.displayProgram("   ") == nil)
    }

    /// Third review: names that differ only in case may be one Keychain item.
    @Test func aNameDifferingOnlyInCaseIsTaken() throws {
        let f = try fixture()
        let you = CredentialVault.Caller(consumer: .user, label: "you")
        try f.vault.set("GH_TOKEN", value: "ghp_first-value-123", scope: nil, note: nil, by: you)
        #expect(throws: CredentialVault.Failure.exists("GH_TOKEN")) {
            try f.vault.set("gh_token", value: "other-value-456", scope: nil, note: nil, by: you)
        }
        #expect(try f.secrets.value(for: "GH_TOKEN") == "ghp_first-value-123")
    }

    /// Fourth review: a decline held only that one ask back, so the next name brought the next
    /// sheet at once; a request that ended unanswered (Ctrl-C) held the person's own next ask
    /// back; `vault.request` opened a sheet over an open approval.
    @Test func aDeclineHoldsEveryAskBrieflyAndAnUnansweredSheetHoldsNothing() async throws {
        let f = try fixture(answer: nil)
        let you = CredentialVault.Caller(consumer: .user, label: "you")
        try f.vault.set("PROD_DB", value: "postgres://prod-secret", scope: [.user], note: nil, by: you)
        try f.vault.set("STAGE_DB", value: "postgres://stage-secret", scope: [.user], note: nil, by: you)
        let socket = ControlConnectionID(rawValue: 31)
        f.approver.allows.withLock { $0 = false }
        #expect(error(await call(f, "vault.resolve", ["names": ["PROD_DB"]], connection: socket))?.code == "vault.not_approved")
        let other = await call(f, "vault.resolve", ["names": ["STAGE_DB"]], connection: socket)
        #expect(error(other)?.message == CredentialVaultStrings.approvalCooldown, "\(other)")
        #expect(error(await call(f, "vault.request", ["name": "NEW_KEY", "caller": Self.agent], connection: socket))?.code == "vault.not_approved")
        #expect(f.approver.asked.withLock { $0.count } == 1 && f.person.asked.withLock { $0.isEmpty }, "no sheet within the cooldown")

        f.clock.advance(.seconds(11))
        f.approver.allows.withLock { $0 = true }
        #expect(error(await call(f, "vault.resolve", ["names": ["PROD_DB"]], connection: socket))?.code == "vault.not_approved",
                "the declined ask itself waits out the backoff")
        let stage = try await call(f, "vault.resolve", ["names": ["STAGE_DB"]], connection: socket).get()
        #expect(stage.objectValue?["values"]?.objectValue?["STAGE_DB"] == "postgres://stage-secret")

        // The request ends before the person answers: no answer, but no fresh sheet at once either
        // (fifth review: a caller dropped and reopened the same sheet until a click landed).
        f.clock.advance(.seconds(11))
        f.approver.hangs.withLock { $0 = true }
        let closing = ControlConnectionID(rawValue: 32)
        let pending = Task { await self.call(f, "vault.remove", ["name": "STAGE_DB"], connection: closing) }
        for _ in 0..<10_000 where f.approver.parked.withLock({ $0 == nil }) { await Task.yield() }
        // Another sheet waits for the open one: a request is refused, not stacked on top.
        #expect(error(await call(f, "vault.request", ["name": "NEW_KEY", "caller": Self.agent], connection: socket))?.message
            == CredentialVaultStrings.approvalOpen)
        ControlConnectionClosures.shared.closed(closing)
        #expect(error(await pending.value)?.code == "vault.not_approved")
        #expect(try f.secrets.value(for: "STAGE_DB") != nil)
        f.approver.hangs.withLock { $0 = false }
        let held = await call(f, "vault.remove", ["name": "STAGE_DB"], connection: socket)
        #expect(error(held)?.message == CredentialVaultStrings.approvalCooldown, "\(held)")
        f.clock.advance(.seconds(11))
        let removed = try await call(f, "vault.remove", ["name": "STAGE_DB"], connection: socket).get()
        #expect(removed.objectValue?["existed"] == true, "after the cooldown the next ask shows its sheet")

        // A request whose connection closed before its sheet opened shows it for no one.
        f.approver.hangs.withLock { $0 = true }
        // ControlConnectionClosures is process-wide and remembers closed ids: one no other test uses.
        let gone = ControlConnectionID(rawValue: 9_034)
        ControlConnectionClosures.shared.closed(gone)
        #expect(error(await call(f, "vault.remove", ["name": "PROD_DB"], connection: gone))?.code == "vault.not_approved")
        f.approver.hangs.withLock { $0 = false }
        #expect(try f.secrets.value(for: "PROD_DB") != nil)
    }

    /// Fourth review: a remove or scope change of a name the vault does not hold showed a sheet,
    /// a set that the vault would refuse for its spelling showed one, and a remove of an absent name
    /// reached the Keychain (which may match another name's item without regard to case).
    @Test func anAskTheVaultWouldRefuseShowsNoSheetAndAnAbsentNameNeverReachesTheKeychain() async throws {
        let f = try fixture()
        let you = CredentialVault.Caller(consumer: .user, label: "you")
        try f.vault.set("GH_TOKEN", value: "ghp_first-value-123", scope: [.user], note: nil, by: you)
        let socket = ControlConnectionID(rawValue: 33)
        #expect(error(await call(f, "vault.scope", ["name": "NOPE", "scope": "agents"], connection: socket))?.code == "vault.missing")
        let absent = try await call(f, "vault.remove", ["name": "gh_token"], connection: socket).get()
        #expect(absent.objectValue?["existed"] == false)
        #expect(error(await call(f, "vault.set", ["name": "gh_token", "value": "other-value-456"], connection: socket))?.code == "vault.exists")
        #expect(f.approver.asked.withLock { $0.isEmpty })
        #expect(try f.vault.remove("gh_token", by: you) == false)
        #expect(f.secrets.deletes.withLock { $0 } == 0)
        #expect(try f.secrets.value(for: "GH_TOKEN") == "ghp_first-value-123")

        // The store sheet always says who may use the value once stored.
        _ = try await call(f, "vault.set", ["name": "NEW_KEY", "value": "new-value-1234"], connection: socket).get()
        _ = try await call(f, "vault.set", ["name": "GH_TOKEN", "value": "ghp_second-value-456"], connection: socket).get()
        #expect(f.approver.asked.withLock { $0 } == [.store(name: "NEW_KEY", replaces: false, scope: [.user, .agents]),
                                                     .store(name: "GH_TOKEN", replaces: true, scope: [.user])])
        let sheet = CredentialVault.approvalSheet(.store(name: "GH_TOKEN", replaces: true, scope: [.user]))
        #expect(sheet.lines.contains(CredentialVaultStrings.approveScopeLine([.user])))
    }

    /// Fourth review: after the third approval the read was never tried again, so an allowed use
    /// was refused.
    @Test func theReadRunsAgainAfterTheLastApproval() async throws {
        let f = try fixture()
        let you = CredentialVault.Caller(consumer: .user, label: "you")
        for name in ["A_KEY", "B_KEY", "C_KEY"] {
            try f.vault.set(name, value: "value-of-\(name)", scope: name == "A_KEY" ? [.user] : nil, note: nil, by: you)
        }
        // Each approval makes the next one kept for the person, as a change in Settings would.
        let vault = f.vault, approver = f.approver
        f.approver.onAsk.withLock {
            $0 = {
                let next = ["B_KEY", "C_KEY"].dropFirst(approver.asked.withLock { $0.count } - 1).first
                if let next { try? vault.setScope(next, scope: [.user], by: you) }
            }
        }
        let read = try await call(f, "vault.resolve", ["names": ["A_KEY", "B_KEY", "C_KEY"]], connection: ControlConnectionID(rawValue: 34)).get()
        #expect(read.objectValue?["values"]?.objectValue?.count == 3)
        #expect(f.approver.asked.withLock { $0.map(VaultControl.ApprovalGate.names) } == [["A_KEY"], ["B_KEY"], ["C_KEY"]])
    }

    /// Fourth review: an agent's reason reached the sheet with line breaks and direction marks.
    @Test func aReasonIsOnePlainLine() {
        #expect(CredentialVault.oneLine("run\n\nthe eval\u{202E}  now\u{200B}") == "run the eval now")
        #expect(CredentialVault.oneLine(" \u{2028}\t ") == nil)
        #expect(CredentialVault.oneLine(String(repeating: "x", count: 500))?.count == CredentialVault.maxNoteCharacters)
    }

    /// Fourth review: a sheet a socket call opened took the keyboard, so typing meant for the
    /// terminal filled its value and a Return saved it.
    @Test func aSheetASocketCallOpenedTakesNoKeyboard() {
        let request = CredentialVault.EntryRequest(name: "GH_TOKEN", reason: nil, requester: "the Chief", replaces: false, unprompted: true)
        let spec = CredentialVault.entrySheet(request)
        #expect(!spec.focusesField)
        #expect(spec.defaultButton == nil)
        #expect(spec.buttons.first { $0.id == CredentialVault.entrySaveButton }?.clickOnly == true)
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == nil)
        let own = CredentialVault.entrySheet(CredentialVault.EntryRequest(name: "", reason: nil, requester: "", replaces: false))
        #expect(own.focusesField && own.defaultButton?.id == CredentialVault.entrySaveButton, "the person's own Add keeps its keys")
        for approval: CredentialVault.Approval in [.use(names: ["K"], program: nil), .remove(name: "K")] {
            #expect(CredentialVault.approvalSheet(approval).buttons.first { $0.id == CredentialVault.approvalAllowButton }?.clickOnly == true)
        }
    }
}
