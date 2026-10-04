import CmuxNextApps
import CmuxNextPages
import CmuxNextSettings

/// The owner side of the React CodeRouter page (`cmux.coderouter.*`): the same `coderouter.*` ops
/// the CodeRouter app calls (``CodeRouterAppOps``), so the page and the app read one accounts
/// service and the same redaction applies. An op this build lacks answers
/// `cmux.operation.unsupported`, which the page shows as "Not available in this build".
@MainActor
final class CodeRouterPageProvider: PageProvider {
    private let ops: CodeRouterAppOps

    init(ops: CodeRouterAppOps) {
        self.ops = ops
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(PageDescriptor.coderouter.namespaces[0]) else { throw PageError.unknownOp(op) }
        let request = AppHostCapabilityRequest(app: "cmux/coderouter", op: String(op.dropFirst("cmux.".count)),
                                               params: AppJSON(params), origin: context.origin)
        do {
            return try await ops.handle(request).settingsValue
        } catch {
            throw PageError(code: error.code.hasPrefix("cmux.") ? error.code : "cmux." + error.code, message: error.message,
                            retryable: error.retryable)
        }
    }
}
