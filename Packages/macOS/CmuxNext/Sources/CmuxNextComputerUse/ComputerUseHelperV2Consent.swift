// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// The app's half of the helper's machine-consent questions. The helper
/// writes `{"type":"machine_consent","id":N}` on the host consent socket
/// (``ComputerUseHelperV2HostLink``; never its stdin) before running a
/// tool; the app answers from its own acpmux daemon with
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

    /// Answers the helper's questions on `link` until it closes. Other lines
    /// (the helper's `{"ok":true}` or a refusal of this app) are logged.
    static func serve(_ link: ComputerUseHelperV2HostLink, pid: pid_t,
                      consent: @escaping @Sendable () async -> Data?,
                      refused: @escaping @Sendable (String) async -> Void) async {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-v2")
        let send: @Sendable (Data) async -> Void = { line in await link.send(line) }
        for await line in link.lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  !handle(object, send: send, consent: consent, refused: refused) else { continue }
            let text = String(decoding: line.prefix(512), as: UTF8.self)
            logger.notice("cmux Computer Use helper v2 host link pid=\(pid, privacy: .public) \(text, privacy: .public)")
        }
    }

    /// Handles one line from the helper's host consent socket. True when it was a consent
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
