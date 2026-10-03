import CmuxNextApps
import CmuxNextCodeRouter
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// What `accounts.list` and the app operation path give a caller (CLI,
/// MCP, apps): `{account: "acct_…", label: "<redacted display>"}`, never an
/// email. Every value here is invented.
@MainActor
@Suite struct AccountsSocketPrivacyTests {
    private struct NoKeychainItems: KeychainProbing {
        func hasGenericPassword(service: String) -> Bool { service == "Claude Code-credentials" }
    }

    private struct NoServers: LocalServerProbing {
        func isReachable(_ url: URL) async -> Bool { false }
    }

    private struct Executor: ControlActionExecutor {
        @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    private static let labeler = AccountLabeler(salt: Data(repeating: 0x42, count: 32))

    /// A home whose Codex, Claude Code and Gemini sign-ins all name emails.
    private func detections() async throws -> [ProviderDetection] {
        let home = FileManager.default.temporaryDirectory.appending(path: "cmux-accounts-socket-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ relative: String, _ object: Any) throws {
            let url = home.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        func segment(_ object: Any) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let idToken = try segment(["alg": "none"]) + "." + segment(["email": "someone@example.com"]) + ".fake-signature"
        try write(".codex/auth.json", ["tokens": ["id_token": idToken, "refresh_token": "fake", "access_token": "fake", "account_id": "x"]])
        try write(".claude.json", ["oauthAccount": ["emailAddress": "someone@example.com"]])
        try write(".gemini/oauth_creds.json", ["refresh_token": "fake"])
        try write(".gemini/google_accounts.json", ["active": "other@example.org"])
        let environment = DetectionEnvironment(home: home, environment: [:], files: LiveFileReader(), keychain: NoKeychainItems(),
                                               servers: NoServers(), labeler: Self.labeler)
        return await ProviderDetector(environment: environment).detectAll()
    }

    @Test func accountsListRowsCarryHandlesAndNoEmail() async throws {
        let found = try await detections()
        let linked = [
            LinkedAccount(id: "a1", family: .native, provider: .codex, account: Self.labeler.server(namespace: "codex", label: "someone@example.com"),
                          state: "active"),
            LinkedAccount(id: "c1", family: .claude, provider: .claude, account: Self.labeler.server(namespace: "claude", label: "someone@example.com"),
                          state: "active"),
        ]
        var withAccount = 0
        for provider in AIProvider.allCases {
            var row = AccountRowState(provider: provider)
            row.reduce(.cmuxSignIn(true))
            if let detection = found.first(where: { $0.provider == provider }) { row.reduce(.detected(detection)) }
            row.reduce(.linkedLoaded(linked))
            let json = AppControl.json(row)
            let text = json.compactText
            #expect(PrivacyScan.emails(in: text).isEmpty, "\(provider): \(text)")
            let object = try #require(json.objectValue)
            #expect(object["identity"] == nil, "the old field is gone")
            if let handle = object["account"]?.stringValue {
                withAccount += 1
                #expect(handle.hasPrefix("acct_"))
                #expect(object["label"]?.stringValue?.isEmpty == false)
            }
            for entry in object["linked"]?.arrayValue ?? [] {
                #expect(entry.objectValue?["account"]?.stringValue?.hasPrefix("acct_") == true)
            }
        }
        #expect(withAccount == 3, "codex, claude and gemini found an account")
    }

    /// No app operation returns account data today: detection and the
    /// CodeRouter lists are not routed to apps. A new route must keep the
    /// label shape and update this test.
    @Test func appOperationsDoNotExposeAccounts() async throws {
        let identity = ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test", processID: getpid())
        let router = AppOperationRouter(router: ControlRouter(identity: identity, executor: Executor()),
                                        storage: AppStorageStore(directory: FileManager.default.temporaryDirectory
                                            .appending(path: "cmux-app-storage-\(UUID().uuidString)")),
                                        ledger: { [] })
        for op in ["coderouter.detect", "coderouter.accounts.list", "accounts.list", "auth.status"] {
            let result = await router.perform(AppOperationRequest(app: "cmux/test", appVersion: "1", op: op, params: .object([:])))
            switch result {
            case .success(let value): Issue.record("\(op) returned \(value)")
            case .failure(let error):
                #expect(error.code == "operation.unsupported", "\(op)")
                #expect(PrivacyScan.emails(in: error.message).isEmpty)
            }
        }
    }
}
