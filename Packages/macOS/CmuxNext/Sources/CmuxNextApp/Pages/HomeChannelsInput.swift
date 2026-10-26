import CmuxNextHibernation
import CmuxNextPages
import CmuxNextSettings

/// Whether one Channels page's composers hold text or files not sent yet. The page reports each
/// change (`cmux.host.home.input.unsent {unsent}`, webviews hostUnsentInput.ts), as Chrome's
/// renderer reports a page's form interaction to the browser
/// (components/performance_manager/public/graph/page_node.h, `HadFormInteraction`). While it
/// does, the page is kept: a discarded page would lose that input (`CannotDiscardReason.formInput`,
/// Chrome's `kFormInteractions` in discard_eligibility_policy.cc).
@MainActor
final class HomeChannelsInput: PageProvider {
    nonisolated static let prefix = "cmux.host.home.input."
    nonisolated static let unsentOp = prefix + "unsent"

    /// The page's last report; false until it reports (a page that has not loaded holds nothing).
    private(set) var unsent = false

    /// The discard keep reasons this input gives its page.
    var keepReasons: [CannotDiscardReason] { unsent ? [.formInput] : [] }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op == Self.unsentOp else { throw PageError.unknownOp(op) }
        guard let unsent = params.objectValue?["unsent"]?.boolValue else {
            throw PageError(code: "cmux.home.invalid_input_state", message: "unsent must be a boolean", retryable: false)
        }
        self.unsent = unsent
        return .object([:])
    }
}
