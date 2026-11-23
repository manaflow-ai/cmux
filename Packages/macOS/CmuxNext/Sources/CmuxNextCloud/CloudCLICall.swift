public import CmuxNextDaemon
public import Foundation

/// One stdin-JSON call of the bundled `cmux` (`cmux cloud <subcommand>`, cmux-tui `cli/cloud_*.rs`):
/// the request goes on the child's stdin (a credential never goes in argv), the answer is its last
/// stdout line. Cloud logic lives in that Rust; Swift only runs it. Every one-shot Cloud subcommand
/// the app runs goes through this one runner.
public struct CloudCLICall: Sendable {
    /// The app's bundled `cmux` (or `CMUX_NEXT_TUI_BIN`).
    public let cli: BundledExecutable

    public init(cli: BundledExecutable) { self.cli = cli }

    /// Why a call gave no answer line: no `cmux` in this build, or a child that failed, timed out or printed none.
    public struct NoAnswer: Error, Sendable, CustomStringConvertible {
        public var description: String
    }

    /// Runs `cmux <arguments>` with `stdin`; the last non-empty stdout line.
    public func run(_ arguments: [String], stdin: Data, timeout: Duration) async throws -> Data {
        guard let binary = await cli.resolve() else { throw NoAnswer(description: "this build has no cmux") }
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, stdin: stdin,
                                                 timeout: timeout, clock: ContinuousClock())
        guard let line = result.stdout.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }) else {
            throw NoAnswer(description: "cmux \(arguments.joined(separator: " ")) answered nothing (exit \(result.status))")
        }
        return Data(line)
    }

    /// `cmux cloud automation-relay` as the signed-in person of `auth`: what `cmux automation
    /// --target cloud`, the Automations page and the Chief's automation tool call (the app's
    /// `cloud.automation`). The forward takes `{op, params?, idempotency_key?}` as JSON bytes and
    /// answers `{ok: true, value}` or `{ok: false, error: {code, message, details?}}`; the rules are
    /// cmux-tui's `cmux_cloud_wire::automation`. The token is read per call, never stored.
    @MainActor
    public func automationRelay(signedIn auth: CloudAuth) -> @Sendable (Data) async -> Data {
        let api = auth.configuration.ownerAPIBaseURL().absoluteString
        let token: @Sendable () async -> Result<String?, any Error> = { @MainActor [weak auth] in
            guard let auth, auth.isSignedIn else { return .success(nil) }
            do { return .success(try await auth.tokens().access) } catch { return .failure(error) }
        }
        return { [self] request in
            let credential: String?
            switch await token() {
            case let .success(found): credential = found
            case let .failure(error): return Self.unreachable(String(describing: error))
            }
            // The request is parsed and re-encoded inside the envelope, so its bytes can never add a field of their own.
            let parsed = (try? JSONSerialization.jsonObject(with: request, options: .fragmentsAllowed)) ?? NSNull()
            let envelope: [String: Any] = ["api": api, "credential": credential.map { $0 as Any } ?? NSNull(), "request": parsed]
            guard let stdin = try? JSONSerialization.data(withJSONObject: envelope) else { return Self.unreachable("the request is not JSON") }
            do {
                return try await run(["cloud", "automation-relay"], stdin: stdin, timeout: .seconds(25))
            } catch {
                return Self.unreachable(String(describing: error))
            }
        }
    }

    /// `cmux cloud api` (cmux-tui `cli/cloud_api.rs`, the cmux-cloud-api crate behind the daemon's
    /// `cloud.<call>` ops) on this Mac's daemon at `socket`, as the signed-in person of `auth` on the platform origin, worker auth. The
    /// answer line as is: `{"ok": true, "body": B}` or `{"ok": false, "error": {"kind", "code", "message", …}}`.
    /// The token is read per call and goes on stdin, never in argv.
    @MainActor
    func cloudAPI(_ call: String, args: [String: any Sendable], signedIn auth: CloudAuth, socket: String) async -> Data {
        let failed = { (kind: String, message: String) in
            (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": ["kind": kind, "message": message]])) ?? Data()
        }
        guard auth.isSignedIn, let credential = try? await auth.tokens().access else { return failed("not_signed_in", "") }
        var request: [String: Any] = ["call": call, "api": auth.configuration.relayAPIBaseURL().absoluteString, "auth": "worker",
                                      "credential": credential, "args": args]
        if let team = auth.teamID { request["team"] = team }
        guard let stdin = try? JSONSerialization.data(withJSONObject: request) else { return failed("transport", "the request is not JSON") }
        do {
            return try await run(["--socket", socket, "cloud", "api"], stdin: stdin, timeout: .seconds(60))
        } catch {
            return failed("transport", String(describing: error))
        }
    }

    /// Share with Me on a teammate's Cloud machine's refused chat start (the agent pane's
    /// `machine.share.self`): cmux-platform's `PUT /v1/machines/{id}/chat-grants/{user}` for the
    /// signed-in person, sent by the cmux-cloud-api crate (`machine.share_chat` with `me`) on this Mac's daemon at `socket`. Nil once
    /// the person may start chats there; else the platform's refusal code (`machine.creator_or_admin`,
    /// `machine.private`, …) or the call's failure kind (`not_signed_in`, `timed_out`, `transport`, …), and its message.
    @MainActor
    public func shareChatWithMe(machine: String, signedIn auth: CloudAuth, socket: String?) async -> (code: String, message: String)? {
        guard let user = auth.platformUserID else { return ("not_signed_in", "") }
        guard let socket else { return ("transport", "") }
        struct Answer: Decodable {
            struct Failure: Decodable { var kind: String?; var code: String?; var message: String? }
            var ok: Bool
            var error: Failure?
        }
        let line = await cloudAPI("machine.share_chat", args: ["machine": machine, "user": user, "me": true], signedIn: auth, socket: socket)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: line) else { return ("transport", "") }
        return answer.ok ? nil : (answer.error?.code ?? answer.error?.kind ?? "transport", answer.error?.message ?? "")
    }

    /// `cmux cloud auth-handoff-relay` (cmux-tui `cli/cloud_auth_handoff_relay.rs`) for `auth.handoff.mint` and
    /// `auth.handoff.redeem` (`cmux auth handoff`): `op` is `mint` or `redeem`, the request its params as JSON
    /// bytes, the answer `{ok: true, value}` or `{ok: false, error: {code, message}}`. The two cmux-api requests and
    /// their rules are that Rust's. This hands it the signed-in human Stack session for a mint (read per call, on
    /// stdin, never argv) and the account signed in now for a redeem, signs in with the session a redeem answers
    /// through the browser sign-in's own completion, and answers only the reply, never a token. A redeem whose
    /// account changed while it ran signs nothing in.
    @MainActor
    public func authHandoffRelay(signedIn auth: CloudAuth) -> @Sendable (String, Data) async -> Data {
        let api = auth.configuration.ownerAPIBaseURL().absoluteString
        let account: @Sendable (Bool) async -> (credential: String?, user: String?) = { @MainActor [weak auth] mint in
            guard let auth else { return (nil, nil) }
            if mint {
                guard await auth.restoredAccessToken() != nil, let access = try? await auth.tokens().access else { return (nil, nil) }
                return (access, nil)
            }
            await auth.awaitRestored()
            return (nil, auth.isSignedIn ? auth.user?.id : nil)
        }
        let signIn: @Sendable (String?, String, String) async -> Bool = { @MainActor [weak auth] before, access, refresh in
            guard let auth, (auth.isSignedIn ? auth.user?.id : nil) == before else { return false }
            return await auth.browserSignIn.completeHandoff(accessToken: access, refreshToken: refresh)
        }
        let unchanged: @Sendable (String?) async -> Bool = { @MainActor [weak auth] before in
            guard let auth else { return false }
            return (auth.isSignedIn ? auth.user?.id : nil) == before
        }
        return { [self] op, request in
            let mint = op == "mint"
            let (credential, before) = await account(mint)
            if mint, credential == nil { return Self.handoffRefusal("not_signed_in", "Sign in to cmux on this Mac first.") }
            guard let stdin = Self.handoffEnvelope(api: api, credential: credential, op: op, request: request, expectedUser: before),
                  let line = try? await run(["cloud", "auth-handoff-relay"], stdin: stdin, timeout: .seconds(23)) else {
                return Self.handoffUnavailable
            }
            guard !mint, let redeemed = Self.handoffRedeemed(line) else { return line }
            if let session = redeemed.session {
                guard await signIn(before, session.access, session.refresh) else { return Self.handoffUnavailable }
            } else if await !unchanged(before) {
                return Self.handoffUnavailable
            }
            return redeemed.reply
        }
    }

    /// The relay's stdin: the origin, the credential and the request (`device` and `code` from the params, `op` and
    /// `expected_user` this app's own).
    nonisolated private static func handoffEnvelope(api: String, credential: String?, op: String, request: Data, expectedUser: String?) -> Data? {
        let params = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
        var body = params.filter { $0.key == "device" || $0.key == "code" }
        body["op"] = op
        if let expectedUser { body["expected_user"] = expectedUser }
        let envelope: [String: Any] = ["api": api, "credential": credential.map { $0 as Any } ?? NSNull(), "request": body]
        return try? JSONSerialization.data(withJSONObject: envelope)
    }

    /// A redeem's `{session, reply}`: the session's tokens, if any, and the reply as an answer line; nil for a refusal.
    nonisolated private static func handoffRedeemed(_ line: Data) -> (session: (access: String, refresh: String)?, reply: Data)? {
        guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], answer["ok"] as? Bool == true,
              let value = answer["value"] as? [String: Any], let reply = value["reply"] as? [String: Any],
              let replyLine = try? JSONSerialization.data(withJSONObject: ["ok": true, "value": reply]) else { return nil }
        let session = value["session"] as? [String: Any]
        guard let session else { return (nil, replyLine) }
        guard let access = session["access_token"] as? String, let refresh = session["refresh_token"] as? String else {
            return (nil, handoffUnavailable)
        }
        return ((access, refresh), replyLine)
    }

    nonisolated private static func handoffRefusal(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": ["code": code, "message": message]])) ?? Data()
    }

    nonisolated private static var handoffUnavailable: Data {
        handoffRefusal("unavailable", "cmux could not be reached. Try again in a moment.")
    }

    private static func unreachable(_ message: String) -> Data {
        let answer: [String: Any] = ["ok": false, "error": ["code": "owner.unreachable", "message": message]]
        return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(#"{"ok":false,"error":{"code":"owner.unreachable","message":""}}"#.utf8)
    }
}
