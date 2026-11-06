public import Foundation

/// Secrets and harness logins sealed end to end to a Cloud machine (design/cloud-carrier.md, item 5):
/// the bundled cmux (`cmux carrier secrets`, cmux-tui `carrier/secrets.rs`) dials the machine's
/// carrier, seals each value with HPKE to the daemon key the session pinned, and sends it as a
/// `secrets-v1` request the machine's daemon opens and writes 0600. This only forwards: one JSON request
/// on the child's stdin (values and the credential never go in argv or the environment), one JSON line back.
extension CloudAPIClient {
    /// The machine's answer: how many secrets it wrote, the login it installed, or why it refused.
    public enum SealedDelivery: Sendable, Equatable {
        case wrote(Int)
        case installed(String)
        /// `code` is a dial step (`ticket`, `relay`, `parked_timeout`, `handshake`), `unsupported` (a machine
        /// without `secrets-v1`), `unpinned`, `refused` (with the machine's fixed `refusal`: `bad-name`,
        /// `replay`, `not-ready`, ...), `bad_request` or `transport`. Never a value or a machine's own text.
        case failed(code: String, refusal: String?, retryable: Bool)
    }

    /// Replaces the machine's `~/.config/cmux/machine-secrets.env` with exactly `values`.
    public func deliverSealedSecrets(_ id: String, values: [(name: String, value: String)]) async throws -> SealedDelivery {
        try await sealed(id, [
            "op": "replace-machine-secrets",
            "values": values.map { ["name": $0.name, "value": $0.value] },
        ])
    }

    /// Installs `harness`'s login (`claude` or `codex`) where the machine's harness reads it.
    public func installSealedLogin(_ id: String, harness: String, login: Data, allowTeamGuest: Bool) async throws -> SealedDelivery {
        try await sealed(id, [
            "op": "install-harness-login", "harness": harness,
            "login_base64": login.base64EncodedString(), "allow_team_guest": allowTeamGuest,
        ])
    }

    /// The carrier's one deadline (180 s) and the child's own exit after it.
    static let sealedDeliveryTimeout: Duration = .seconds(200)

    private func sealed(_ id: String, _ fields: [String: any Sendable]) async throws -> SealedDelivery {
        guard let machineIO else { throw CloudAPIError.transport("this build has no bundled cmux") }
        let access: String
        do { access = try await tokens().access } catch { throw CloudAPIError.notSignedIn }
        var request = fields
        request["api"] = baseURL.absoluteString
        request["credential"] = access
        let input = try JSONSerialization.data(withJSONObject: request)
        let output: Data
        do {
            output = try await CloudMachineIO.run(machineIO.binary, arguments: ["carrier", "secrets", "--machine", id],
                                                  stdin: input, timeout: Self.sealedDeliveryTimeout, work: machineIO.work)
        } catch is CloudMachineIO.NoAnswer {
            return .failed(code: "transport", refusal: nil, retryable: true)
        }
        return Self.sealedAnswer(output)
    }

    /// The child's last stdout line as an answer; anything else is `transport`.
    static func sealedAnswer(_ output: Data) -> SealedDelivery {
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            return .failed(code: "transport", refusal: nil, retryable: true)
        }
        if object["ok"] as? Bool == true {
            if let count = object["count"] as? Int { return .wrote(count) }
            if let installed = object["installed"] as? String { return .installed(installed) }
        }
        return .failed(code: object["error_code"] as? String ?? "transport", refusal: object["refusal"] as? String,
                       retryable: object["retryable"] as? Bool ?? false)
    }
}
