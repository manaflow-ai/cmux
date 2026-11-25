public import Foundation

/// Secrets sealed end to end to a Cloud machine (design/cloud-carrier.md, item 5):
/// the bundled cmux (`cmux carrier secrets`, cmux-tui `carrier/secrets.rs`) dials the machine's
/// carrier, seals each value with HPKE (with the time it was sealed) to the daemon key the session
/// pinned, and sends it as a
/// `secrets-v1` request the machine's daemon opens and writes 0600. This only forwards: one JSON request
/// on the child's stdin (values and the credential never go in argv or the environment), one JSON line back.
extension CloudAPIClient {
    /// The machine's answer: how many secrets it wrote, or why it refused.
    public enum SealedDelivery: Sendable, Equatable {
        case wrote(Int)
        /// `code` is a dial step (`ticket`, `relay`, `parked_timeout`, `handshake`), `timeout` (the deadline passed after the dial), `unsupported` (a machine
        /// without `secrets-v1`), `refused` (with the machine's fixed `refusal`: `bad-name`, `replay`,
        /// `stale`, the retryable `busy`, ...), `bad_request` or `transport`. Never a value or a machine's own text.
        case failed(code: String, refusal: String?, retryable: Bool)
    }

    /// Replaces the machine's `~/.config/cmux/machine-secrets.env` with exactly `values`.
    public func deliverSealedSecrets(_ id: String, values: [(name: String, value: String)]) async throws -> SealedDelivery {
        try await sealed(id, [
            "op": "replace-machine-secrets",
            "values": values.map { ["name": $0.name, "value": $0.value] },
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
        // The machine's team, as `cmux carrier dial --team` sends it: a shared team's machine needs it.
        // Only a platform team id (`team_` and 20 lowercase hex digits); the child refuses anything else.
        if let team = await currentTeam(), Self.isPlatformTeam(team) { request["team"] = team }
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

    /// `team_` and 20 lowercase hex digits (cmux-platform's team id).
    static func isPlatformTeam(_ id: String) -> Bool {
        guard id.hasPrefix("team_") else { return false }
        let tail = id.utf8.dropFirst(5)
        return tail.count == 20 && tail.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The child's last stdout line as an answer; anything else is `transport`.
    static func sealedAnswer(_ output: Data) -> SealedDelivery {
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            return .failed(code: "transport", refusal: nil, retryable: true)
        }
        if object["ok"] as? Bool == true {
            if let count = object["count"] as? Int { return .wrote(count) }
        }
        return .failed(code: object["error_code"] as? String ?? "transport", refusal: object["refusal"] as? String,
                       retryable: object["retryable"] as? Bool ?? false)
    }
}
