import CmuxNextApps
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The CodeRouter app's ops over the control methods: status, accounts (no
/// email ever leaves), unsupported ops, and dispatch by family.
struct CodeRouterAppOpsTests {
    private nonisolated final class Calls: @unchecked Sendable {
        var methods: [String] = []
    }

    private func ops(_ calls: Calls, reply: @escaping @Sendable (String) -> JSONValue) -> CodeRouterAppOps {
        CodeRouterAppOps(control: { method, _ throws(AppHostCapabilityError) in
            calls.methods.append(method)
            return reply(method)
        })
    }

    private func request(_ op: String) -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "cmux/coderouter", op: op, params: .object([:]), origin: "script")
    }

    @Test func statusComesFromTheAccountsSignIn() async throws {
        let calls = Calls()
        let handler = ops(calls) { _ in .object(["signed_in": .bool(true), "refreshing": .bool(false)]) }
        let status = try await handler.handle(request("coderouter.status"))
        #expect(status["signed_in"]?.boolValue == true)
        #expect(status["health"]?.stringValue == "ok")
        #expect(calls.methods == ["accounts.list"])
    }

    @Test func accountRowsNeverCarryAnEmail() async throws {
        let calls = Calls()
        let handler = ops(calls) { _ in
            .object(["accounts": .array([.object(["account": .string("acct_abc"), "label": .string("someone@example.com"),
                                                  "note": .string("owner: Person.Name+x@corp.example.org")])])])
        }
        let value = try await handler.handle(request("coderouter.accounts.list"))
        let text = String(describing: value)
        #expect(!text.contains("someone@example.com"))
        #expect(!text.contains("corp.example.org"))
        #expect(text.contains("acct_abc"))
        #expect(calls.methods == ["coderouter.accounts.list"])
        #expect(CodeRouterAppOps.redactEmails("a someone@example.com b") == "a s…@e… b")
    }

    @Test func opsWithoutABackingMethodAreUnsupported() async {
        let handler = ops(Calls()) { _ in .null }
        await #expect(throws: AppHostCapabilityError.self) { try await handler.handle(request("coderouter.keys.create")) }
        let capabilities = AppHostCapabilities([handler])
        #expect(capabilities.handles("coderouter.status"))
        #expect(!capabilities.handles("fs.read"))
        do {
            _ = try await capabilities.handle(request("coderouter.keys.create"))
            Issue.record("expected unsupported")
        } catch {
            #expect(error.code == "operation.unsupported")
        }
    }
}
