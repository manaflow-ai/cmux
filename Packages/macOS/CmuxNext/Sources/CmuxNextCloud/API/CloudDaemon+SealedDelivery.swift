public import Foundation

/// Secrets sealed end to end to a Cloud machine (design/cloud-carrier.md, item 5):
/// the bundled cmux (`cmux carrier secrets`, cmux-tui `carrier/secrets.rs`) dials the machine's
/// carrier, seals each value with HPKE (with the time it was sealed) to the daemon key the session
/// pinned, and sends it as a
/// `secrets-v1` request the machine's daemon opens and writes 0600. This only forwards: one JSON request
/// on the child's stdin (values and the credential never go in argv or the environment), one JSON line back.
extension CloudDaemon {
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

    /// What carrying the person's GitHub login to a machine did (`git-host-tokens-v1`, `cmux carrier secrets`
    /// `use-github-login`): the bundled cmux reads this Mac's own `gh` login itself, so its token never passes
    /// through the app.
    public enum GitHubLoginCarry: Sendable, Equatable {
        /// The machine has it; `login` is its GitHub login when gh said.
        case carried(login: String?)
        /// This Mac has no gh login for github.com.
        case noLogin
        /// The machine was not reached or refused (an older machine says `unsupported`).
        case failed(code: String)
        /// Removed from the machine (`forget`).
        case forgotten
    }

    /// Carries this Mac's own gh login to machine `id` (Leo, 2026-11-25: "Convienient beats all. Just make good
    /// ui for it so people flow."). Bounded by `deadline`: a start never waits on it longer.
    /// nil, with nothing sent, when `on` is false (`cloud.useMyGitHubLogin` off).
    public func carryGitHubLogin(_ id: String, if on: Bool, deadline: Duration = .seconds(25)) async -> GitHubLoginCarry? {
        on ? await carryGitHubLogin(id, deadline: deadline) : nil
    }

    private func carryGitHubLogin(_ id: String, deadline: Duration) async -> GitHubLoginCarry {
        let answer: [String: Any]
        do { answer = try await sealedLine(id, ["op": "use-github-login"], deadline: deadline) } catch {
            return .failed(code: "transport")
        }
        if answer["ok"] as? Bool == true { return .carried(login: answer["login"] as? String) }
        let code = answer["error_code"] as? String ?? "transport"
        return code == "no_gh_login" ? .noLogin : .failed(code: code)
    }

    /// Removes the person's carried GitHub login from machine `id`.
    public func forgetGitHubLogin(_ id: String) async -> GitHubLoginCarry {
        let answer: [String: Any]
        do { answer = try await sealedLine(id, ["op": "replace-git-host-token", "host": "github.com"], deadline: .seconds(60)) } catch {
            return .failed(code: "transport")
        }
        return answer["ok"] as? Bool == true ? .forgotten : .failed(code: answer["error_code"] as? String ?? "transport")
    }

    /// One `carrier secrets` request with its own deadline; its answer line as an object.
    private func sealedLine(_ id: String, _ fields: [String: any Sendable], deadline: Duration) async throws -> [String: Any] {
        guard let machineIO else { throw CloudAPIError.transport("this build has no bundled cmux") }
        let access: String
        do { access = try await tokens().access } catch { throw CloudAPIError.notSignedIn }
        var request = fields
        request["api"] = baseURL.absoluteString
        request["credential"] = access
        if let team = await teamID(), Self.isPlatformTeam(team) { request["team"] = team }
        let input = try JSONSerialization.data(withJSONObject: request)
        let millis = max(1_000, Int(deadline.components.seconds) * 1_000)
        let output = try await CloudMachineIO.run(machineIO.binary, arguments: ["carrier", "secrets", "--machine", id, "--deadline-ms", String(millis)],
                                                  stdin: input, timeout: deadline + .seconds(10), work: machineIO.work)
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return [:] }
        return object
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
        if let team = await teamID(), Self.isPlatformTeam(team) { request["team"] = team }
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
