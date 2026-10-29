import CmuxNextPages
import Foundation

/// Settings' switches that widen what another machine may do on this Mac: a paired device's Full access
/// (its chats edit files and run commands here without asking) and a Cloud machine's Dedicated agent
/// machine (this Mac's chats run there without the sandbox). An agent that drives this Mac's screen
/// must not be able to turn either on for itself.
extension SettingsPageProvider {
    enum WideningSwitch {
        case fullAccess, vmHost

        /// The confirm's reason, which macOS shows as "cmux is trying to <reason>."
        var reason: String {
            switch self {
            case .fullAccess: SettingsPersonGateStrings.fullAccessReason
            case .vmHost: SettingsPersonGateStrings.vmHostReason
            }
        }
    }

    /// SECURITY: an on needs the person's own click or key in the Settings page, spent once (the host's
    /// record, never the page's word), and that input must be the person's own:
    /// - the HID system's (``PersonInputLedger``, `personBacksGesture`): it turns the switch on with no
    ///   prompt, as before;
    /// - anything else (Screen Sharing, Universal Control, the Accessibility Keyboard, or a click another
    ///   process posted, the way a computer-use agent clicks): the person confirms with Touch ID or the
    ///   login password (`ownerConfirm`), which a posted click cannot answer. Only a confirm that
    ///   succeeds turns it on; a cancel, a failure, a Mac that cannot ask, or a second ask while one is
    ///   up leaves it off.
    /// The gesture is spent before the confirm, so a script riding the same click cannot reuse it.
    /// An off only narrows, so its caller asks for none of this.
    func personTurnsOn(_ widening: WideningSwitch, _ context: PageCallContext) async throws {
        let refusal = PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        guard context.page == PageDescriptor.settings.id, context.userGesture, let event = context.gestureEvent,
              event != spentFullAccessGesture else { throw refusal }
        spentFullAccessGesture = event
        if personBacksGesture?(event) == true { return }
        guard !confirmingOwner, let ownerConfirm else { throw refusal }
        confirmingOwner = true
        defer { confirmingOwner = false }
        guard await ownerConfirm.authenticate(reason: widening.reason) else { throw refusal }
    }
}

/// The turn-on confirm's reasons (Resources/Remote.xcstrings).
nonisolated enum SettingsPersonGateStrings {
    static var fullAccessReason: String {
        text("settings.personGate.fullAccessReason", "turn on Full access, so another machine's chats can edit files and run commands on this Mac without asking")
    }

    static var vmHostReason: String {
        text("settings.personGate.vmHostReason", "turn on Dedicated agent machine, so this Mac's chats run on that Cloud machine without the sandbox")
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Remote", bundle: .module)
    }
}
