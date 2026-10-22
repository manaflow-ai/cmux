import CmuxNextDesign
import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings

/// Settings > Chief > Voice input (Leo's list): the message box's mic, which is the Debug toggle
/// `home.voiceInput` itself (on by default, Leo 2026-10-20). The row exists only where that tunable
/// does: the store is active in DEV and NIGHTLY, and Release keeps the code default with no row.
///
/// - The page reads `voice_input` in the host lists: `{on}`, or null without the tunable.
/// - `set {on}`: writes the tunable, on the person's click on Settings only.
@MainActor
final class ChiefVoiceInputPageRoute: PageProvider {
    nonisolated static let prefix = "cmux.settings.voice_input."

    private let store: TunableStore
    private let tunable = HomeTunables.voiceInput

    init(store: TunableStore = .shared) {
        self.store = store
    }

    /// The host lists' `voice_input`. Reading it registers an Observation dependency on the tunable,
    /// so the page's host-lists watch re-sends it after a change from Debug Settings.
    var hostJSON: JSONValue {
        store.isActive ? ["on": .bool(tunable.value(in: store))] : .null
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix + "set" else { throw PageError.unknownOp(op) }
        guard store.isActive else { throw PageError.unavailable("this build has no Debug Settings") }
        guard context.page == PageDescriptor.settings.id, context.userGesture else {
            throw PageError(code: "cmux.settings.user_only", message: "only you can turn the mic on or off")
        }
        guard case .bool(let on)? = params["on"] else { throw PageError.invalidParams("on is required") }
        store.set(tunable.key, .bool(on))
        return .object([:])
    }
}
