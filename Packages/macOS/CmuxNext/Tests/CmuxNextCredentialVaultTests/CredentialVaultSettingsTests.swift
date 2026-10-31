import CmuxNextCompat
@testable import CmuxNextCredentialVault
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Chief > Credential Vault (cmux issue 26412): the card shows every secret's name, scope
/// and last use, follows changes made anywhere (the CLI's too), and takes its gestures only from the
/// person's click on Settings. No host list ever holds a value.
@MainActor @Suite(.serialized) struct CredentialVaultSettingsTests {
    static let secret = "ghp_settingsCard0123456789abcdefABCDEF"
    static let person = CredentialVault.Caller(consumer: .user, label: "you")
    private static var gestures: TimeInterval = 0
    /// A new click on Settings each time: the route spends each gesture once.
    static var settings: PageCallContext {
        gestures += 1
        return PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: gestures)
    }

    private func vault() -> CredentialVault {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        return CredentialVault(secrets: CredentialVaultControlTests.MemorySecrets(), folder: folder)
    }

    private func secrets(_ board: CredentialVaultBoard) -> [JSONValue] {
        board.hostJSON["secrets"]?.arrayValue ?? []
    }

    @Test func rolloutHidesMetadataAndRefusesNativePageOperationsWhileOff() async throws {
        let store = TunableStore()
        store.register([CredentialVault.rolloutEnabled.descriptor])
        store.activate(file: nil)
        let board = CredentialVaultBoard(vault: vault(), enabled: { CredentialVault.rolloutEnabled.value(in: store) })
        let route = CredentialVaultPageRoute(board: board, window: { nil }, enabled: { CredentialVault.rolloutEnabled.value(in: store) })
        #expect(board.hostJSON == .null)
        for action in ["add", "replace", "remove", "scope"] {
            do {
                _ = try await route.call(CredentialVaultPageRoute.prefix + action, params: [:], context: Self.settings)
                Issue.record("disabled vault accepted \(action)")
            } catch let error as PageError {
                #expect(error.code == "vault.disabled")
            }
        }
        store.set(CredentialVault.rolloutEnabled.key, .bool(true))
        #expect(board.hostJSON != .null)
        store.set(CredentialVault.rolloutEnabled.key, .bool(false))
        #expect(board.hostJSON == .null)
    }

    @Test func theBoardListsNamesAndScopesAndFollowsEveryChangeWithoutAValue() async throws {
        let vault = vault()
        try vault.set("GH_TOKEN", value: Self.secret, scope: [.user], note: "work", by: Self.person)
        let board = CredentialVaultBoard(vault: vault, enabled: { true })
        await board.reload().value
        let row = try #require(secrets(board).first?.objectValue)
        #expect(row["name"] == "GH_TOKEN")
        #expect(row["scope"] == ["user"])
        #expect(row["note"] == "work")
        #expect(board.hostJSON["loaded"] == true)

        // A change from elsewhere (`cmux vault set`) reaches the board through onChange.
        try vault.set("OPENAI_API_KEY", value: "sk-proj-0123456789abcdefghij", scope: nil, note: nil, by: Self.person)
        for _ in 0..<200 where secrets(board).count < 2 { await Task.yield() }
        #expect(secrets(board).compactMap { $0.objectValue?["name"]?.stringValue } == ["GH_TOKEN", "OPENAI_API_KEY"])
        _ = try vault.resolve(["GH_TOKEN"], for: Self.person, command: "gh pr create")
        for _ in 0..<200 where secrets(board).first?.objectValue?["uses"] != 1 { await Task.yield() }
        #expect(secrets(board).first?.objectValue?["uses"] == 1, "a use shows as its last use")
        #expect(!"\(board.hostJSON)".contains(Self.secret), "the host lists never hold a value")
    }

    @Test func theScopeSwitchWritesOnlyOnThePersonsClickOnSettings() async throws {
        let vault = vault()
        try vault.set("GH_TOKEN", value: Self.secret, scope: nil, note: nil, by: Self.person)
        let board = CredentialVaultBoard(vault: vault, enabled: { true })
        await board.reload().value
        let route = CredentialVaultPageRoute(board: board, window: { nil }, enabled: { true })
        let op = CredentialVaultPageRoute.prefix + "scope"
        let params: JSONValue = ["name": "GH_TOKEN", "scope": ["user"]]
        for context in [PageCallContext(page: PageDescriptor.settings.id), PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: 1),
                        PageCallContext(page: PageDescriptor.settings.id, userGesture: true)] {
            await #expect(throws: PageError.self) { _ = try await route.call(op, params: params, context: context) }
        }
        #expect(try vault.list()["GH_TOKEN"]?.scope == [.user, .agents], "no gesture, no change")

        let click = Self.settings
        #expect(try await route.call(op, params: params, context: click) == ["done": true])
        // A second call riding the same click (a script in the page, a debug probe) is refused.
        await #expect(throws: PageError.self) {
            _ = try await route.call(op, params: ["name": "GH_TOKEN", "scope": ["user", "agents"]], context: click)
        }
        #expect(try vault.list()["GH_TOKEN"]?.scope == [.user])
        #expect(secrets(board).first?.objectValue?["scope"] == ["user"])

        await #expect(throws: PageError.self) {
            _ = try await route.call(op, params: ["name": "GH_TOKEN", "scope": []], context: Self.settings)
        }
        await #expect(throws: PageError.self) {
            _ = try await route.call(op, params: ["name": "NOT_THERE", "scope": ["user"]], context: Self.settings)
        }
        await #expect(throws: PageError.self) {
            _ = try await route.call(CredentialVaultPageRoute.prefix + "export", params: [:], context: Self.settings)
        }
    }

    /// Sixth review: in a DEV build a synthetic key or click in Settings counts as a gesture, so the
    /// Agents switch could hand a secret kept for the person to agents. Widening a scope to agents
    /// waits for the person's approval sheet; narrowing it does not.
    @Test func lettingAgentsUseASecretWaitsForThePersonsApproval() async throws {
        let vault = vault()
        try vault.set("PROD_DB", value: Self.secret, scope: [.user], note: nil, by: Self.person)
        let board = CredentialVaultBoard(vault: vault, enabled: { true })
        await board.reload().value
        let answer = Mutex(false)
        let asked = Mutex([CredentialVault.Approval]())
        let route = CredentialVaultPageRoute(board: board, window: { nil }, enabled: { true }, approve: { approval in
            asked.withLock { $0.append(approval) }
            return answer.withLock { $0 }
        })
        let op = CredentialVaultPageRoute.prefix + "scope"
        let widen: JSONValue = ["name": "PROD_DB", "scope": ["user", "agents"]]
        #expect(try await route.call(op, params: widen, context: Self.settings) == ["done": false])
        #expect(try vault.list()["PROD_DB"]?.scope == [.user], "declined: agents still may not use it")
        answer.withLock { $0 = true }
        #expect(try await route.call(op, params: widen, context: Self.settings) == ["done": true])
        #expect(try vault.list()["PROD_DB"]?.scope == [.user, .agents])
        #expect(asked.withLock { $0 } == [.scope(name: "PROD_DB", scope: [.user, .agents]), .scope(name: "PROD_DB", scope: [.user, .agents])])
        #expect(try await route.call(op, params: ["name": "PROD_DB", "scope": ["user"]], context: Self.settings) == ["done": true])
        #expect(asked.withLock { $0.count } == 2, "taking agents off asks nothing")
    }

    /// A scope revoked elsewhere is authoritative before the board's asynchronous refresh.
    /// Synthetic Settings gestures must not restore the board's formerly agent-usable scope.
    @Test func aStaleBoardCannotRestoreAgentAccessWithoutApproval() async throws {
        let vault = vault()
        try vault.set("PROD_DB", value: Self.secret, scope: [.user, .agents], note: nil, by: Self.person)
        let board = CredentialVaultBoard(vault: vault, enabled: { true })
        await board.reload().value
        let asked = Mutex([CredentialVault.Approval]())
        let route = CredentialVaultPageRoute(board: board, window: { nil }, enabled: { true }, approve: { approval in
            asked.withLock { $0.append(approval) }
            return false
        })
        // No await between revocation and the route: the board still shows the old scope.
        try vault.setScope("PROD_DB", scope: [.user], by: Self.person)
        #expect(board.entries["PROD_DB"]?.scope == [.user, .agents])
        let result = try await route.call(CredentialVaultPageRoute.prefix + "scope",
                                          params: ["name": "PROD_DB", "scope": ["user", "agents"]], context: Self.settings)
        #expect(result == ["done": false])
        #expect(asked.withLock { $0 } == [.scope(name: "PROD_DB", scope: [.user, .agents])])
        #expect(try vault.list()["PROD_DB"]?.scope == [.user])
        #expect(throws: CredentialVault.Failure.denied(["PROD_DB"], .agents)) {
            try vault.resolve(["PROD_DB"], for: .init(consumer: .agents, label: "agent"), command: nil, approved: [])
        }
    }

    @Test func addAsksForTheNameAndReplaceKeepsTheSecretsScope() throws {
        let add = CredentialVault.EntryRequest(name: "", reason: nil, requester: "", replaces: false)
        let spec = CredentialVault.entrySheet(add)
        #expect(spec.title == CredentialVaultStrings.entryAddTitle)
        #expect(spec.fields.contains { $0.id == CredentialVault.entryNameField }, "Add names the secret on the sheet")
        let save = CredentialVault.entrySaveButton
        let named = CmuxDialogAnswer(button: save, role: .default, values: [CredentialVault.entryNameField: .text("NPM_TOKEN"),
                                                                            CredentialVault.entryValueField: .text("npm_x1234"),
                                                                            CredentialVault.entryAgentsField: .bool(true)])
        #expect(CredentialVault.entryAnswer(named, request: add) == .init(name: "NPM_TOKEN", value: "npm_x1234", scope: [.user, .agents]))

        let replace = CredentialVault.EntryRequest(name: "GH_TOKEN", reason: nil, requester: "", replaces: true, scope: [.agents])
        let replaceSpec = CredentialVault.entrySheet(replace)
        #expect(!replaceSpec.fields.contains { $0.id == CredentialVault.entryNameField })
        #expect(replaceSpec.fields.contains(.check(id: CredentialVault.entryAgentsField, title: CredentialVaultStrings.entryAgentsCheck, on: true)))
        let kept = CmuxDialogAnswer(button: save, role: .default, values: [CredentialVault.entryValueField: .text("ghp_new"),
                                                                           CredentialVault.entryAgentsField: .bool(true)])
        #expect(CredentialVault.entryAnswer(kept, request: replace)?.scope == [.agents], "an agents-only secret stays agents-only")
        let delete = CredentialVaultPageRoute.deleteSheet("GH_TOKEN")
        #expect(delete.identifier == CredentialVaultPageRoute.deleteDialogIdentifier)
        #expect(delete.buttons.contains { $0.id == CredentialVaultPageRoute.deleteButton && $0.role == .destructive })
    }
}
