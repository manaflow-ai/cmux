import Foundation
import Testing
@testable import CmuxNextCodeRouter

/// The Codex handle is HMAC(workspace id + user id) on every side: local
/// detection, the typed CodeRouter row and the redacted socket reply. No
/// label (email-shaped or not) ever changes it. Handles are not persisted
/// anywhere, so these equalities are the whole migration contract.
@Suite struct CodexAccountHandleTests {
    /// The typed row (`LinkedAccount`) and the redacted passthrough row of one server account.
    func serverHandles(label: String?, workspace: String?, user: String?, id: String = "a1") throws -> (typed: AccountLabel, socket: String) {
        var row: [String: Any] = ["id": id, "provider": "codex", "state": "active"]
        row["label"] = label
        row["providerAccountId"] = workspace
        row["providerUserId"] = user
        let data = try JSONSerialization.data(withJSONObject: ["accounts": [row]])
        let decoded = try JSONDecoder().decode(NativeList.self, from: data).accounts[0]
        let typed = try #require(LinkedAccount(native: decoded, labeler: fixtureLabeler))
        let redacted = AccountJSONRedactor(labeler: fixtureLabeler, accountRows: true).redact(data)
        #expect(PrivacyScan.emails(inJSON: redacted).isEmpty, "\(String(decoding: redacted, as: UTF8.self))")
        #expect(PrivacyScan.emails(inReflectionOf: typed).isEmpty, "\(typed)")
        let object = try #require(try JSONSerialization.jsonObject(with: redacted) as? [String: Any])
        let socketRow = try #require((object["accounts"] as? [[String: Any]])?.first)
        #expect(socketRow["providerAccountId"] == nil && socketRow["providerUserId"] == nil, "provider ids are dropped")
        let socket = try #require(socketRow["account"] as? String)
        #expect(socket == typed.account.handle, "socket and typed handles agree")
        return (typed.account, socket)
    }

    struct NativeList: Decodable { var accounts: [NativeAccountRow] }

    func localAccount(_ auth: [String: Any]) throws -> AccountLabel? {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", auth)
        let detection = ProviderDetector(environment: home.environment()).detectCodex()
        #expect(PrivacyScan.emails(inReflectionOf: detection).isEmpty, "\(detection)")
        #expect(PrivacyScan.emails(inJSON: try JSONEncoder().encode(detection)).isEmpty)
        return detection.account
    }

    @Test func renamingAnEmailShapedLabelKeepsTheHandle() throws {
        let labels: [String?] = ["dev@example.com", "other@example.com", "Work", "work (dev@example.com)", nil]
        let handles = try labels.map { try serverHandles(label: $0, workspace: "ws-1", user: "user-1").typed.handle }
        #expect(Set(handles).count == 1, "the label never feeds the handle")
        #expect(handles[0] == codexHandle(workspace: "ws-1", user: "user-1"))
    }

    @Test func twoUsersInOneWorkspaceGetDifferentHandles() throws {
        let first = try serverHandles(label: "Team", workspace: "ws-shared", user: "user-a", id: "a1").typed
        let second = try serverHandles(label: "Team", workspace: "ws-shared", user: "user-b", id: "a2").typed
        #expect(first.handle != second.handle)
        let localFirst = try #require(try localAccount(codexAuth(email: "a@example.com", workspace: "ws-shared", user: "user-a")))
        let localSecond = try #require(try localAccount(codexAuth(email: "a@example.com", workspace: "ws-shared", user: "user-b")))
        #expect(localFirst.handle != localSecond.handle, "the same email in two user ids stays two accounts")
    }

    @Test func localDetectionAndServerRowOfOneAccountMatch() throws {
        let local = try #require(try localAccount(codexAuth(email: "dev@example.com", workspace: "ws-1", user: "user-1")))
        let server = try serverHandles(label: "renamed@example.com", workspace: "ws-1", user: "user-1")
        #expect(local.handle == server.typed.handle)
        #expect(local.handle == server.socket)
        // A changed email claim with the same ids is the same account.
        let reissued = try #require(try localAccount(codexAuth(email: "new@example.com", workspace: "ws-1", user: "user-1")))
        #expect(reissued.handle == local.handle)
    }

    @Test func claimsAreReadWhereTheServerReadsThem() throws {
        // The legacy `user_id` under the auth claim, and ids in the access token.
        let legacy = fakeJWT(["email": "dev@example.com", "https://api.openai.com/auth": ["user_id": "user-1", "chatgpt_account_id": "ws-1"]])
        let accessOnly = fakeJWT(["exp": 1_900_003_600, "chatgpt_user_id": "user-1", "chatgpt_account_id": "ws-1"])
        let expected = codexHandle(workspace: "ws-1", user: "user-1")
        for (idToken, accessToken) in [(legacy, fakeJWT(["exp": 1_900_003_600])), (fakeJWT(["email": "dev@example.com"]), accessOnly)] {
            let auth: [String: Any] = ["tokens": ["id_token": idToken, "access_token": accessToken, "refresh_token": "r", "account_id": "ws-1"]]
            #expect(try localAccount(auth)?.handle == expected)
        }
        // Two different user ids are no user id (the server refuses that credential).
        let split: [String: Any] = ["tokens": [
            "id_token": fakeJWT(["chatgpt_user_id": "user-1", "chatgpt_account_id": "ws-1"]),
            "access_token": fakeJWT(["chatgpt_user_id": "user-2"]), "refresh_token": "r", "account_id": "ws-1",
        ]]
        #expect(try localAccount(split)?.handle == fixtureLabeler.handle(namespace: "codex", identity: "codex:workspace:ws-1"))
    }

    @Test func missingUserIdFallsBackWithoutTheLabel() throws {
        // Workspace only: a legacy server row and a token without a user claim agree.
        let workspaceOnly = fixtureLabeler.handle(namespace: "codex", identity: "codex:workspace:ws-1")
        for label in ["a@example.com", "b@example.com", "Work"] {
            #expect(try serverHandles(label: label, workspace: "ws-1", user: nil).typed.handle == workspaceOnly)
        }
        #expect(try localAccount(codexAuth(workspace: "ws-1", user: nil))?.handle == workspaceOnly)
        // Neither id: the row id, never the label.
        let byRow = try ["a@example.com", "Work"].map { try serverHandles(label: $0, workspace: nil, user: nil, id: "row-9").typed.handle }
        #expect(byRow[0] == byRow[1])
        #expect(byRow[0] == fixtureLabeler.handle(namespace: "codex", identity: "id:row-9"))
        #expect(byRow[0] != fixtureLabeler.handle(namespace: "codex", identity: "a@example.com"))
        // Locally, neither id: the token's own email claim; no email either: no account.
        let local = try #require(try localAccount(codexAuth(email: "dev@example.com", workspace: nil, user: nil)))
        #expect(local.handle == fixtureLabeler.handle(namespace: "codex", identity: "dev@example.com"))
        #expect(local.display == "pro")
        #expect(try localAccount(["tokens": ["id_token": fakeJWT([:]), "refresh_token": "r"]]) == nil)
    }

    @Test func idsCannotShiftTheIdentityFields() {
        let joined = CodexAccountIdentity(workspaceID: "ws:user:u", userID: nil).identity
        let split = CodexAccountIdentity(workspaceID: "ws", userID: "u").identity
        #expect(joined != split)
        #expect(CodexAccountIdentity(workspaceID: " ", userID: "").identity == nil, "blank ids are missing")
    }

    @Test func handlesAndDisplaysCarryNoEmail() throws {
        let server = try serverHandles(label: "someone@example.com", workspace: "ws-1", user: "user-1").typed
        #expect(server.display == "s…@e…")
        let local = try #require(try localAccount(codexAuth(email: "someone@example.com", plan: "", workspace: "ws-1", user: "user-1")))
        #expect(local.display == "s…@e…")
        for label in [server, local] {
            #expect(AccountLabel.isValidHandle(label.handle))
            #expect(PrivacyScan.emails(in: label.description).isEmpty)
            #expect(!label.description.contains("ws-1") && !label.description.contains("user-1"), "raw ids stay out too")
        }
    }
}
