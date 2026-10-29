// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app's half of the helper's machine-consent questions. The helper
/// writes `{"type":"machine_consent","id":N}` on its control pipe before
/// running a tool; the app answers from its own acpmux daemon with
/// `{"type":"machine_consent","id":N,"ok":true,"result":{...}}`, or
/// `"ok":false` when the daemon gives no answer. The question carries
/// nothing the answer depends on.
nonisolated enum ComputerUseHelperV2Consent {
    /// The answer line for question `id`, given the daemon's raw result.
    static func answer(id: Int, result: Data?) -> Data {
        guard let result, let object = try? JSONSerialization.jsonObject(with: result),
              object is [String: Any] else {
            return ComputerUseHelperV2.line(["type": "machine_consent", "id": id, "ok": false])
        }
        return ComputerUseHelperV2.line(["type": "machine_consent", "id": id, "ok": true, "result": object])
    }

    /// Handles one control line from the helper. True when it was a consent
    /// line (answered or forwarded); such lines are not logged, since the
    /// helper sends one per tool call.
    static func handle(_ object: [String: Any], send: @escaping @Sendable (Data) async -> Void,
                       consent: @escaping @Sendable () async -> Data?,
                       refused: @escaping @Sendable (String) async -> Void) -> Bool {
        switch object["type"] as? String {
        case "machine_consent":
            guard let id = object["id"] as? Int else { return true }
            // task-owner: one bounded daemon question per helper question (AcpmuxMachineConsent.deadline); it ends with its answer.
            Task { await send(answer(id: id, result: await consent())) }
            return true
        case "consent_refused":
            if let surface = object["surface"] as? String {
                // task-owner: one best-effort, deadline-bounded record per refused call.
                Task { await refused(surface) }
            }
            return true
        default:
            return false
        }
    }
}
