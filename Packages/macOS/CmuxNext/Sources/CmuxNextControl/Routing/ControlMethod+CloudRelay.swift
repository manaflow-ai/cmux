public import CmuxNextActions
public import CmuxNextSettings
public import Foundation

extension ControlMethod {
    /// One Cloud call the signed-in person makes through a CmuxNextCloud relay (`cloud.automation`:
    /// `cmux cloud automation-relay`; `cloud.apps`: `cmux cloud apps-relay`, what `cmux app ls|versions`
    /// read off a Cloud machine): routing only. Off with Cloud; otherwise `relay` gets the params as JSON
    /// and its answer line, `{ok, value}` or `{ok: false, error}`, is returned as is for the CLI to read.
    /// The requests and their rules are Rust; no token crosses this socket.
    public static func cloudRelay(
        _ name: String,
        seconds: Int,
        disabledFeatures: @escaping @MainActor @Sendable () -> Set<ActionFeature>,
        relay: @escaping @Sendable (Data) async -> Data
    ) -> ControlMethod {
        .async(name) { call in
            let disabled = await MainActor.run { disabledFeatures() }
            if let refusal = ControlError.policyRefusal(name, disabled: disabled) { throw refusal }
            let reply = await relay(try JSONSerialization.data(withJSONObject: JSONValue.object(call.params).foundationObject))
            return JSONValue(foundation: try JSONSerialization.jsonObject(with: reply)) ?? .null
        }.withDeadline(.fixed(.seconds(seconds)))
    }
}
