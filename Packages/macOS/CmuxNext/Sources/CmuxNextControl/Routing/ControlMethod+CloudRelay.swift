public import CmuxNextActions
public import CmuxNextSettings
public import Foundation

extension ControlMethod {
    /// One Cloud call the signed-in person makes through a CmuxNextCloud relay (`cloud.automation`:
    /// `cmux cloud automation-relay`; `cloud.apps`: `cmux cloud apps-relay`, what `cmux app ls|versions`
    /// read off a Cloud machine): routing only. Off with Cloud; otherwise `relay` gets the params as JSON
    /// and its answer line, `{ok, value}` or `{ok: false, error}`, is returned as is for the CLI to read.
    /// The requests and their rules are Rust; no token crosses this socket. `mayCallCloud` is the app's
    /// whole Cloud gate past the policy (a managed team missing, a local-only backend): false refuses the
    /// call with `cloud_disabled` before any credential leaves, so none is ever sent unscoped.
    public static func cloudRelay(
        _ name: String,
        seconds: Int,
        disabledFeatures: @escaping @MainActor @Sendable () -> Set<ActionFeature>,
        mayCallCloud: @escaping @MainActor @Sendable () -> Bool,
        relay: @escaping @Sendable (Data) async -> Data
    ) -> ControlMethod {
        .async(name) { call in
            let (disabled, open) = await MainActor.run { (disabledFeatures(), mayCallCloud()) }
            if let refusal = ControlError.policyRefusal(name, disabled: disabled) { throw refusal }
            guard open else { throw ControlError.cloudUnavailable }
            let reply = await relay(try JSONSerialization.data(withJSONObject: JSONValue.object(call.params).foundationObject))
            return JSONValue(foundation: try JSONSerialization.jsonObject(with: reply)) ?? .null
        }.withDeadline(.fixed(.seconds(seconds)))
    }
}

extension ControlError {
    /// `cloud_disabled`: this Mac may not call Cloud for the signed-in account or team.
    static var cloudUnavailable: ControlError {
        ControlError(code: "cloud_disabled", message: ControlStrings.text("control.error.cloudUnavailable", "cmux Cloud is not available for this account or team."))
    }
}
