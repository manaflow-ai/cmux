public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > Devices' ops for Control between the person's devices (``RemoteControlConsent``) and the
/// Macs this machine trusts (``JoinConsentModel/trustGrantor(_:trusted:)``), served whole as parts of the
/// Settings page. Each answers `{}` or `{error}`:
/// - `cmux.settings.devices.remote_control {id, on}`: one machine on, off, or `null` (back to the switch for all)
/// - `cmux.settings.devices.remote_control_account {on}`: the switch for all the person's devices
/// - `cmux.settings.devices.trust_refresh {}`: "Refresh trusted Macs"
/// - `cmux.settings.devices.grantor_trust {id, trusted}`: Allow, Not now and Remove of another Mac's key
///
/// SECURITY: an on signs a grant with this Mac's key that turns Control and Screen sharing on elsewhere (or
/// trusts another Mac's key here), so it takes the person's own HID click or key in this page, spent once
/// on the shared gate as `join_consent`'s on, and then Touch ID or the password (``PageWideningGate/widen``):
/// an agent driving the page with posted input never signs or trusts. A refresh takes the click only (it
/// grants nothing, but pins the account's keys). Off, back-to-default, Not now and Remove only narrow and
/// take any input.
@MainActor public final class RemoteControlConsentPage: PageProvider {
    public static let ops = ["cmux.settings.devices.remote_control", "cmux.settings.devices.remote_control_account",
                             "cmux.settings.devices.trust_refresh", "cmux.settings.devices.grantor_trust"]
    /// What each op does once let through (the error to show, or nil); tests record them.
    public struct Actions {
        public var setMachine: @MainActor (_ id: String, _ on: Bool?) async -> String?
        public var setAccount: @MainActor (_ on: Bool) async -> String?
        public var refreshTrust: @MainActor () async -> String?
        public var trustGrantor: @MainActor (_ id: String, _ trusted: Bool) async -> String?

        public init(setMachine: @escaping @MainActor (String, Bool?) async -> String?, setAccount: @escaping @MainActor (Bool) async -> String?,
                    refreshTrust: @escaping @MainActor () async -> String?, trustGrantor: @escaping @MainActor (String, Bool) async -> String?) {
            self.setMachine = setMachine
            self.setAccount = setAccount
            self.refreshTrust = refreshTrust
            self.trustGrantor = trustGrantor
        }

        /// The app's: ``RemoteControlConsent`` and the join model's key trust.
        public static func over(_ consent: RemoteControlConsent, join: JoinConsentModel) -> Self {
            Self(setMachine: { [weak consent] in await consent?.set(machineID: $0, on: $1) },
                 setAccount: { [weak consent] in await consent?.setAccount(on: $0) },
                 refreshTrust: { [weak consent] in await consent?.refreshTrust() },
                 trustGrantor: { [weak join] in await join?.trustGrantor($0, trusted: $1) })
        }
    }

    private let actions: Actions
    private let gate: PageWideningGate
    private let backs: (@MainActor (TimeInterval) -> Bool)?
    private let confirm: (@MainActor (String) async -> Bool)?
    private let refusal: PageError

    /// `gate`: the app's one widening gate (a click is spent once across pages); `backs`: the person's own HID
    /// input at an uptime (the app's ``PersonInputLedger``); `confirm`: Touch ID or the password with a reason
    /// (nil: never confirmed); `refusal`: the page's person-only error.
    public init(actions: Actions, gate: PageWideningGate, backs: (@MainActor (TimeInterval) -> Bool)?,
                confirm: (@MainActor (String) async -> Bool)?, refusal: PageError) {
        self.actions = actions
        self.gate = gate
        self.backs = backs
        self.confirm = confirm
        self.refusal = refusal
    }

    /// This part under each of its ops, for the Settings provider's `parts`.
    public var parts: [String: any PageProvider] { Dictionary(uniqueKeysWithValues: Self.ops.map { ($0, self as any PageProvider) }) }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let error: String?
        switch op {
        case "cmux.settings.devices.remote_control":
            guard let id = params["id"]?.stringValue, !id.isEmpty, let on = params["on"], on == .null || on.boolValue != nil else {
                throw PageError.invalidParams("id and on (true, false or null) are required")
            }
            let value = on.boolValue
            // SECURITY: null (back to the account-wide grant) turns the machine on when the account is on, so
            // it takes the person's gesture and Touch ID as an on does; only an off narrows.
            error = try await widen("remoteControl \(id)", value != false, context, RemoteControlStrings.confirmReason) { [actions] _ in
                await actions.setMachine(id, value)
            }
        case "cmux.settings.devices.remote_control_account":
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("on is required") }
            error = try await widen("remoteControl *", on, context, RemoteControlStrings.accountConfirmReason, actions.setAccount)
        case "cmux.settings.devices.trust_refresh":
            guard gate.claimPerson(context, backs: backs) else { throw refusal }
            error = await actions.refreshTrust()
        case "cmux.settings.devices.grantor_trust":
            guard let id = params["id"]?.stringValue, !id.isEmpty, let trusted = params["trusted"]?.boolValue else {
                throw PageError.invalidParams("id and trusted are required")
            }
            error = try await widen("grantorTrust \(id)", trusted, context, JoinConsentStrings.grantorTrustReason) { [actions] in
                await actions.trustGrantor(id, $0)
            }
        default:
            throw PageError.unknownOp(op)
        }
        return error.map { ["error": .string($0)] } ?? .object([:])
    }

    private func widen(_ key: String, _ on: Bool, _ context: PageCallContext, _ reason: String,
                       _ write: @escaping @MainActor (Bool) async -> String?) async throws -> String? {
        var ask: (@MainActor () async -> Bool)?
        if let confirm { ask = { await confirm(reason) } }
        return try await gate.widen(key, on: on, context, backs: backs, confirm: ask, refusal: refusal, write: write)
    }
}
