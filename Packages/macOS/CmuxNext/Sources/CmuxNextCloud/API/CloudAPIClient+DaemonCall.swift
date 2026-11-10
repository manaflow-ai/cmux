import Foundation

/// The cmux daemon's Cloud calls (cmux-tui `cloud.<call>`), sent through the bundled cmux's `cmux cloud api`
/// (cmux-tui `cli/cloud_api.rs`): the sandboxed Runs (`runs.create`, `runs.wait`, `runs.cancel`) live in the
/// daemon, never in classic Cloud's Run API, but for an incognito send's, which the daemon sends there. This only forwards: one JSON request on the child's stdin (the
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
        // An incognito send's create runs on classic Cloud, with no chat in the app, and a wait or cancel of a Run the daemon never
        // made (an incognito one, or one followed from before it ran Runs) drains there, with the Stack session whole (cmux-cloud-api
        // `classic_runs`); no other call carries the refresh token or the classic API. Without it the daemon refuses an incognito create.
        let classicCall = call == "runs.wait" || call == "runs.cancel" || call == "runs.create" && args["incognito"] as? Bool == true
        // A session that could not be read is no answer about the Run: a wait or cancel the daemon then finds no Run for is
        // `transport` (read again), never `run_not_found`, which would drop a live classic Run (#39022 audit at 855beb0d).
        var classicUnread = false
        if classicCall, let classicRuns {
            let classic = try? await classicRuns()
            if let classic, !classic.refresh.isEmpty {
                request["credential"] = classic.access
                request["refresh"] = classic.refresh
                request["args"] = args.merging(["classicApi": classic.api.absoluteString, "classicTeam": classic.team ?? ""]) { $1 }
            } else {
                classicUnread = true
            }
        }
        if let team = await teamID() { request["team"] = team }
        let output: Data
        do {
            output = try await run(try JSONSerialization.data(withJSONObject: request), timeout)
        } catch let noAnswer as CloudMachineIO.NoAnswer {
            // Never started: nothing ran. Started and then killed or crashed: the call may have run.
            if noAnswer.dispatched { throw CloudAPIError.timedOut("cloud.\(call)") }
            throw CloudAPIError.transport("cmux is not available")
        }
        do {
            return try Self.daemonAnswer(output, call: call, baseURL: baseURL)
        } catch CloudAPIError.http(status: 404, code: "run_not_found", message: _, action: _, traceId: _) where classicUnread {
            throw CloudAPIError.transport("cloud.\(call): the Cloud session could not be read")
        }
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
