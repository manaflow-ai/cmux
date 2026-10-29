import CmuxNextPages
import Foundation

/// Settings' switches that widen what another machine may do on this Mac: a paired device's Full access
/// (its chats edit files and run commands here without asking) and a Cloud machine's Dedicated agent
/// machine (this Mac's chats run there without the sandbox). An agent that drives this Mac's screen
/// must not be able to turn either on for itself.
extension SettingsPageProvider {
    enum WideningSwitch {
        case fullAccess, vmHost

        func key(_ id: String) -> String { "\(self) \(id)" }

        /// The confirm's reason, which macOS shows as "cmux is trying to <reason>."
        var reason: String {
            switch self {
            case .fullAccess: SettingsPersonGateStrings.fullAccessReason
            case .vmHost: SettingsPersonGateStrings.vmHostReason
            }
        }
    }

    /// Turns `widening` on or off for machine `id` through `write` (the host's error, or nil).
    ///
    /// SECURITY: an on needs the person's own click or key in the Settings page, spent once (the host's
    /// record, never the page's word), and then Touch ID or the login password (`ownerConfirm`,
    /// LocalAuthentication `deviceOwnerAuthentication`), whatever the click's source says. A click another
    /// process posts can carry the HID system's source fields, so they never skip the confirm, and a
    /// posted click cannot answer it. A cancel, a failure, a Mac that cannot ask (no `ownerConfirm`, or
    /// LocalAuthentication cannot evaluate), or a second ask while one is up leaves it off. The gesture is
    /// spent before the confirm, so a script riding the same click cannot reuse it.
    ///
    /// An off only narrows, so it takes any input with no prompt, and it wins over every on asked before
    /// it: an on still in its confirm, or queued behind another write, is dropped. Writes for one switch
    /// on one machine run one at a time in the order they were asked, so they land in that order.
    func widen(_ widening: WideningSwitch, _ id: String, on: Bool, _ context: PageCallContext,
               _ write: @escaping @MainActor (String, Bool) async -> String?) async throws -> String? {
        let key = widening.key(id)
        let refusal = PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        if on {
            guard context.page == PageDescriptor.settings.id, context.userGesture, let event = context.gestureEvent,
                  event != spentFullAccessGesture else { throw refusal }
            spentFullAccessGesture = event
            guard !confirmingOwner, let ownerConfirm else { throw refusal }
            let offsBefore = offs[key, default: 0]
            confirmingOwner = true
            let confirmed = await ownerConfirm.authenticate(reason: widening.reason)
            confirmingOwner = false
            guard confirmed, offs[key, default: 0] == offsBefore else { throw refusal }
            return try await queued(key, id, on: true, after: offsBefore, write)
        }
        offs[key, default: 0] += 1
        return try await queued(key, id, on: false, after: offs[key, default: 0], write)
    }

    /// Runs one write for `key` after the ones asked before it. An on runs only if no off came in after
    /// it was asked (`after` is the off count it was asked under); otherwise it is refused.
    private func queued(_ key: String, _ id: String, on: Bool, after offsAsked: Int,
                        _ write: @escaping @MainActor (String, Bool) async -> String?) async throws -> String? {
        let previous = writes[key]
        // task-owner: one link of the write chain for one switch on one machine; ends with its host write.
        let task = Task { @MainActor [weak self] () -> String?? in
            await previous?.value
            guard let self else { return .none }
            if on, self.offs[key, default: 0] != offsAsked { return .none }
            return .some(await write(id, on))
        }
        // task-owner: the chain's tail, which the next write for this key waits on; ends with `task`.
        writes[key] = Task { _ = await task.value }
        guard let answer = await task.value else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        return answer
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
