import CmuxNextApps
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The owner side of the React CodeRouter page (`cmux.coderouter.*`): the same `coderouter.*` ops
/// the CodeRouter app calls (``CodeRouterAppOps``), so the page and the app read one accounts
/// service and the same redaction applies. A page call reaches the owner as the user's own only
/// after the host's native sheet (`context.confirmed`); every other call is `script`. Connect adds
/// a credential, so `cmux.coderouter.accounts.connect` runs only confirmed. An op this build
/// lacks answers `cmux.operation.unsupported` ("Not available in this build" on the page).
@MainActor
final class CodeRouterPageProvider: PageProvider {
    nonisolated static let connectOp = "cmux.coderouter.accounts.connect"

    private let ops: CodeRouterAppOps
    /// Runs the accounts service's Connect for a provider id (the `accounts.connect` handler).
    private let connect: @MainActor (_ provider: String) -> Bool

    init(ops: CodeRouterAppOps, connect: @escaping @MainActor (_ provider: String) -> Bool) {
        self.ops = ops
        self.connect = connect
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(PageDescriptor.coderouter.namespaces[0]) else { throw PageError.unknownOp(op) }
        if op == Self.connectOp {
            guard context.confirmed else {
                throw PageError(code: "cmux.page.unconfirmed", message: "Connect needs the native confirmation")
            }
            guard let provider = params["provider"]?.stringValue, !provider.isEmpty else {
                throw PageError.invalidParams("provider is required")
            }
            return ["connected": .bool(connect(provider))]
        }
        let request = AppHostCapabilityRequest(app: "cmux/coderouter", op: String(op.dropFirst("cmux.".count)),
                                               params: AppJSON(params), origin: context.confirmed ? "user" : "script")
        do {
            return try await ops.handle(request).settingsValue
        } catch {
            throw PageError(code: error.code.hasPrefix("cmux.") ? error.code : "cmux." + error.code, message: error.message,
                            retryable: error.retryable)
        }
    }
}

/// The native sheets of the CodeRouter page: Connect sends a local sign-in to CodeRouter.
nonisolated enum CodeRouterPageConfirmations {
    static func confirmation(op: String, params: JSONValue) -> PageConfirmation? {
        guard op == CodeRouterPageProvider.connectOp else { return nil }
        let name = params["name"]?.stringValue ?? params["provider"]?.stringValue ?? ""
        return PageConfirmation(kind: .custom, name: String(format: CodeRouterPageStrings.connectTitle, name),
                                detail: CodeRouterPageStrings.connectDetail)
    }
}

nonisolated enum CodeRouterPageStrings {
    static var title: String { String(localized: "coderouter.page.title", defaultValue: "CodeRouter", table: "Accounts", bundle: .module) }
    static var connectTitle: String {
        String(localized: "coderouter.connect.title", defaultValue: "Connect %@ to CodeRouter?", table: "Accounts", bundle: .module)
    }
    static var connectDetail: String {
        String(localized: "coderouter.connect.detail",
               defaultValue: "cmux sends this sign-in to CodeRouter. It stays private until you share it with your team.",
               table: "Accounts", bundle: .module)
    }
}
