public import CmuxNextActions
public import CmuxNextSettings
public import Foundation

extension ControlMethod {
    /// `auth.handoff.mint {device?}` and `auth.handoff.redeem {code, device?}` (`cmux auth handoff`,
    /// cmux-tui `cli/auth_handoff.rs`): routing only. Off with Cloud; otherwise `relay` answers with
    /// the op (`mint` or `redeem`) and the params as JSON, and its answer line `{ok, value}` or
    /// `{ok: false, error: {code, message}}` is this method's value or ``ControlError``, whose code
    /// the CLI maps to its exit code. The app's relay is CmuxNextCloud's `CloudCLICall.authHandoffRelay`,
    /// which runs `cmux cloud auth-handoff-relay`, where the requests and their rules are Rust. No token
    /// crosses this socket, only the one-time code.
    public static func authHandoff(
        disabledFeatures: @escaping @MainActor @Sendable () -> Set<ActionFeature>,
        relay: @escaping @Sendable (String, Data) async -> Data
    ) -> [ControlMethod] {
        [("auth.handoff.mint", "mint"), ("auth.handoff.redeem", "redeem")].map { name, op in
            .async(name) { call in
                let disabled = await MainActor.run { disabledFeatures() }
                if let refusal = ControlError.policyRefusal(name, disabled: disabled) { throw refusal }
                let request = (try? JSONSerialization.data(withJSONObject: JSONValue.object(call.params).foundationObject)) ?? Data("{}".utf8)
                return try authHandoffAnswer(await relay(op, request))
            }.withDeadline(.fixed(.seconds(25)))
        }
    }

    /// An answer line's value, or its refusal as a ``ControlError`` (`unavailable` when it is no answer).
    nonisolated static func authHandoffAnswer(_ line: Data) throws -> JSONValue {
        let answer = (try? JSONSerialization.jsonObject(with: line)).flatMap { JSONValue(foundation: $0) }
        if answer?["ok"]?.boolValue == true, let value = answer?["value"] { return value }
        guard let code = answer?["error"]?["code"]?.stringValue else {
            throw ControlError(code: "unavailable", message: "cmux could not be reached. Try again in a moment.")
        }
        throw ControlError(code: code, message: answer?["error"]?["message"]?.stringValue ?? code)
    }
}
