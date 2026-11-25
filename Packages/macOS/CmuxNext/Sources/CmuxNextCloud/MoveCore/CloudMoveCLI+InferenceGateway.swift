public import CmuxNextDaemon
public import Foundation

/// The inference gateway status reads the Cloud start gate asks before a start (hq#15762, hq#19758).
nonisolated extension CloudMoveCLI {
    /// `cmux inference gateway status --json --team <team> --token-stdin`'s `serves` (Rust `status_answer`): the agents `team`'s
    /// inference gateway serves now, empty when it is off or offline; nil `serves` when the status could not be read, with the
    /// CLI's `error.code` (or ``badAnswer``, ``CloudSetup/GatewayRead/timedOut``) (hq#15762). `team` is the backend team the start's
    /// machines are made in (the install token's): a team's gateway serves only its own machines, so the active team's would wave
    /// through a start no gateway serves. `token` is that install token, which the app already holds, with the API that issued
    /// it (`apiOrigin`), on stdin: the CLI mints none, where its own `cmux auth token --team` (up to 25 s) ran inside this read's
    /// 10 s bound and the gate refused a start the gateway served (hq#19758).
    public func inferenceGatewayStatus(team: String, token: String, apiOrigin: URL) async -> CloudSetup.GatewayRead {
        struct Call: Encodable { var verb = "inference-gateway-status"; var team: String; var held = true }
        let held = (try? JSONSerialization.data(withJSONObject: ["access_token": token, "api_origin": apiOrigin.absoluteString])) ?? Data()
        let out: Data
        do {
            out = try await output(Call(team: team), stdin: held).stdout
        } catch let error as DaemonError {
            if case .timedOut = error { return CloudSetup.GatewayRead(team: team, errorCode: CloudSetup.GatewayRead.timedOut) }
            return CloudSetup.GatewayRead(team: team, errorCode: Self.badAnswer)
        } catch {
            return CloudSetup.GatewayRead(team: team, errorCode: Self.badAnswer)
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] else {
            return CloudSetup.GatewayRead(team: team, errorCode: Self.badAnswer)
        }
        guard answer["ok"] as? Bool == true, let serves = answer["serves"] as? [String] else {
            let code = (answer["error"] as? [String: Any])?["code"] as? String
            return CloudSetup.GatewayRead(team: team, errorCode: code ?? Self.badAnswer)
        }
        return CloudSetup.GatewayRead(team: team, serves: Set(serves))
    }

    /// The same read for a team whose token the app does not hold (the person's own team): the CLI mints it (#51322).
    public func inferenceGatewayServes(team: String) async -> Set<String>? {
        await inferenceGatewayRead(team: team).serves
    }

    /// ``inferenceGatewayServes(team:)`` with why a read gave no `serves`: the status's own error code and message,
    /// or how the run ended (the start gate logs it, so a refused start says which read failed; hq cloud-chat-works).
    public func inferenceGatewayRead(team: String) async -> (serves: Set<String>?, why: String?) {
        let result: ProcessResult
        do { result = try await output(["verb": "inference-gateway-status", "team": team]) } catch { return (nil, "run: \(error)") }
        guard let answer = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            return (nil, "exit \(result.status), no JSON answer")
        }
        guard answer["ok"] as? Bool == true, let serves = answer["serves"] as? [String] else {
            let error = answer["error"] as? [String: Any]
            let code = (error?["code"] as? String) ?? (answer["error_code"] as? String) ?? "-"
            let message = (error?["message"] as? String) ?? (answer["error"] as? String) ?? ""
            return (nil, "exit \(result.status) \(code) \(message.prefix(200))")
        }
        return (Set(serves), nil)
    }

    /// What the gateways of TEAMS serve together (nil teams skipped, each asked once), nil when none answers. A start's
    /// machine can land in either the install token's team or the person's own team: production made every
    /// cloud-chat-replies-production machine in the personal team while the install token named another (cmuxterm-hq
    /// probe rows 2026-11-22/23), and a gateway online there was refused as "No Cloud connection serves claude".
    public func inferenceGatewayServes(teams: [String?]) async -> Set<String>? {
        var asked: Set<String> = [], serves: Set<String>?
        for team in teams.compactMap({ $0 }) where asked.insert(team).inserted {
            if let answer = await inferenceGatewayServes(team: team) { serves = (serves ?? []).union(answer) }
        }
        return serves
    }
}
