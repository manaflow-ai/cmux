import Foundation

/// The cmux daemon's Cloud calls (cmux-tui `cloud.<call>`), sent through the bundled cmux's `cmux cloud api`
/// (cmux-tui `cli/cloud_api.rs`): the sandboxed Runs (`runs.create`, `runs.wait`, `runs.cancel`) live in the
/// daemon, never in classic Cloud's Run API. This only forwards: one JSON request on the child's stdin (the
/// credential never goes in argv), one answer line back, `{"ok": true, "body": B}` or `{"ok": false, "error": E}`,
/// where `E.kind` names a ``CloudAPIError`` case one for one.
extension CloudAPIClient {
    /// `cloud.<call>` with `args`: answers its body as JSON, or throws its failure as a ``CloudAPIError``.
    /// No bundled cmux is `transport` ("cmux is not available"); there is no HTTP fallback. `timeout` bounds the
    /// child (a child past it is killed: `timedOut`, since the call may have run).
    func daemon(_ call: String, _ args: [String: any Sendable], timeout: Duration) async throws -> Data {
        let run: @Sendable (Data, Duration) async throws -> Data
        if let daemonCall {
            run = daemonCall
        } else if let machineIO {
            run = { input, timeout in try await machineIO.cloudAPI(input, timeout: timeout) }
        } else {
            throw CloudAPIError.transport("cmux is not available")
        }
        let access: String
        do { access = try await tokens().access } catch { throw CloudAPIError.notSignedIn }
        var request: [String: any Sendable] = ["call": call, "api": baseURL.absoluteString, "auth": "owner", "credential": access,
                                               "app_version": appVersion, "args": args]
        if let team = await teamID() { request["team"] = team }
        let output: Data
        do {
            output = try await run(try JSONSerialization.data(withJSONObject: request), timeout)
        } catch let noAnswer as CloudMachineIO.NoAnswer {
            // Never started: nothing ran. Started and then killed or crashed: the call may have run.
            if noAnswer.dispatched { throw CloudAPIError.timedOut("cloud.\(call)") }
            throw CloudAPIError.transport("cmux is not available")
        }
        return try Self.daemonAnswer(output, call: call, baseURL: baseURL)
    }

    /// The child's last stdout line as the call's body, or its failure.
    static func daemonAnswer(_ output: Data, call: String, baseURL: URL) throws -> Data {
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            throw CloudAPIError.transport("cmux did not answer cloud.\(call)")
        }
        guard object["ok"] as? Bool == true else {
            throw daemonFailure(object["error"] as? [String: Any] ?? [:], call: call, baseURL: baseURL)
        }
        return try JSONSerialization.data(withJSONObject: object["body"] ?? NSNull(), options: .fragmentsAllowed)
    }

    /// `cmux_cloud_api`'s `Failure` JSON (`kind` and its fields) as the ``CloudAPIError`` case it names.
    static func daemonFailure(_ error: [String: Any], call: String, baseURL: URL) -> CloudAPIError {
        func text(_ name: String) -> String? { (error[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch text("kind") {
        case "timed_out": return .timedOut(text("path") ?? "cloud.\(call)")
        case "transport": return .transport(text("message") ?? "cmux did not answer cloud.\(call)")
        case "no_backend": return .noBackend(baseURL)
        case "http":
            guard let status = error["status"] as? Int else { return .decoding("cloud.\(call): no status") }
            return .http(status: status, code: text("code"), message: text("message"), action: text("action"), traceId: text("trace_id"))
        case "plan_required":
            return .planRequired(message: text("message"), upgradeURL: text("upgrade_url").flatMap { URL(string: $0) }, plan: text("plan") ?? "pro")
        case "decoding": return .decoding(text("message") ?? "cloud.\(call)")
        default: return .decoding("cloud.\(call): unreadable failure")
        }
    }
}
