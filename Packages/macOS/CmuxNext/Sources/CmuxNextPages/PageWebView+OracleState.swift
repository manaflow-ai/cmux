#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
import Foundation

/// The host half of the page call behind the refactor oracle's `webviews` facet (p15-oracle-215,
/// webviews/src/protocol/oracle-state.ts). A DEV or bench build installs ``oracleStateScript`` at document
/// start, so only there does a page register `cmux.page.oracle.state`; a Release build compiles none of this
/// and its pages never serve the op.
extension PageWebView {
    /// The op a page serves (`ORACLE_STATE_OP`).
    public nonisolated static let oracleStateOp = "cmux.page.oracle.state"
    /// Sets the page's gate (`ORACLE_STATE_ENABLED`) before the page's code runs.
    nonisolated static let oracleStateScript = "globalThis.__cmuxOracleState = true;"

    /// What a page said to ``oracleState()``.
    public enum OracleStateAnswer: Sendable {
        /// The page's `{route, selection, panels, draftSha256}`.
        case state(JSONValue)
        /// The document does not serve the op (it does not boot through the shared page client).
        case unserved
        /// The page closed or navigated away while it was asked.
        case gone
    }

    /// Asks the page for its state. Nil while no document of this page runs: it loads, or it is the parked spare,
    /// whose document has no routes yet.
    ///
    /// - Throws: The page's error (`cmux.oracle.no_digest` when it cannot hash its draft).
    public func oracleState() async throws(PageError) -> OracleStateAnswer? {
        guard loaded, !isParkedSpare else { return nil }
        do {
            return .state(try await router.callPage(Self.oracleStateOp, params: .object([:])))
        } catch let error as PageError {
            switch error.code {
            case PageError.unknownOp(Self.oracleStateOp).code: return .unserved
            case PageError.closed.code: return .gone
            default: throw error
            }
        } catch {
            throw PageError(code: "cmux.page.failed", message: String(describing: error))
        }
    }
}
#endif
