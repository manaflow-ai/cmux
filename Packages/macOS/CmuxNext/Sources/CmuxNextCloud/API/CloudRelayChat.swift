public import Foundation

/// The relay-first chat path (cmuxterm-hq#7086; Leo: "it should take <30 seconds from starting a thing to having
/// a response on cloud"): a prompt goes to the machine over HTTPS, `POST /v1/cloud/machines/{id}/chat` on the
/// platform Worker (cmux-platform `MachineRelay`), and down the socket the machine holds from boot (cmux-host
/// `cloud/relay.rs`). No link to the machine is on this path. The answer streams back as NDJSON events
/// (`queued`, `sent`, `started`, `text`, `record`, `permission`, `keepalive`, then `done` or `error`).
///
/// A prompt is never sent twice: an answer says whether it reached the machine (``Answer/delivered``), and only one
/// that did not (the platform refused it, no machine took it) may go another way.
///
/// The person's Stack access token and the cmux team (`x-cmux-team`) only, like the machine exec route: a Mac
/// install token has no execute grant and the route refuses it. Nothing here logs a prompt or a reply.
public nonisolated struct CloudRelayChat: Sendable {
    public let baseURL: URL
    let accessToken: @Sendable () async throws -> String
    let teamID: CloudAPIClient.TeamID
    let session: URLSession

    /// `session` must refuse redirects (the default does): one would carry the bearer and the prompt elsewhere.
    public init(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String, teamID: @escaping CloudAPIClient.TeamID,
                session: URLSession? = nil) {
        (self.baseURL, self.accessToken, self.teamID) = (baseURL, accessToken, teamID)
        self.session = session ?? CloudOwnerAPIClient.transport
    }

    /// What one chat's turn came to.
    public struct Answer: Equatable, Sendable {
        /// The acpmux session on the machine, from `started`.
        public var session: String?
        public var promptID: String?
        /// The agent's reply: `done`'s whole reply, else every `text` event in order.
        public var reply = ""
        /// `done`'s stop reason; nil when the turn ended in an `error`.
        public var stopReason: String?
        /// `error`'s code and message.
        public var errorCode: String?
        public var errorMessage: String?
        /// From the request to the first `text` event, and to the end.
        public var firstText: Duration?
        public var total: Duration?
        /// Whether the machine was not connected yet when the chat arrived (it waited for it).
        public var queued = false
        /// The platform sent the chat down the machine's socket (`sent`).
        public var sent = false
        public var ended: Bool { stopReason != nil || errorCode != nil }
        /// The stream broke or closed before the turn ended (`cloud.relay.closed`): the platform may have sent it.
        public var broken = false
        /// Whether the prompt may be on the machine. False only when it certainly is not: the platform itself ended
        /// the turn (a refusal, or an `error` event) before it sent it. Then it may be sent another way. A turn still
        /// open may yet be sent, and one whose stream broke may have been, so both count.
        public var delivered: Bool { sent || session != nil || !ended || broken }

        public init() {}

        /// Applies one NDJSON line; `at` is the time since the request.
        public mutating func apply(line: String, at: Duration) {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = event["kind"] as? String else { return }
            switch kind {
            case "queued": queued = true
            case "sent": sent = true
            case "started":
                session = event["session"] as? String
                promptID = event["prompt_id"] as? String
            case "text":
                guard let text = event["text"] as? String else { return }
                if firstText == nil { firstText = at }
                reply += text
            case "done":
                stopReason = (event["stop_reason"] as? String) ?? "end_turn"
                if let whole = event["reply"] as? String {
                    if firstText == nil, !whole.isEmpty { firstText = at }
                    reply = whole
                }
                total = at
            case "error":
                errorCode = (event["code"] as? String) ?? "cloud.relay.failed"
                errorMessage = (event["message"] as? String) ?? ""
                total = at
            default: return
            }
        }
    }

    /// The turn so far, for ``answer(_:agent:prompt:cwd:promptID:within:)``.
    actor Progress {
        private(set) var answer = Answer()
        func set(_ answer: Answer) { self.answer = answer }
    }

    /// A machine id the route takes (`vm_` and 20 lowercase letters or digits).
    public static func isMachineID(_ id: String) -> Bool { id.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil }

    /// How long the stream may be quiet: the platform sends a keepalive every 20 s, so this is a dead connection.
    static let idleTimeout: TimeInterval = 90

    /// Sends `prompt` to `agent` on machine `id` and reads the stream to the turn's end, however long it runs.
    public func chat(_ id: String, agent: String, prompt: String, cwd: String? = nil, promptID: String? = nil) async throws -> Answer {
        try await chat(id, agent: agent, prompt: prompt, cwd: cwd, promptID: promptID, startWithin: nil, progress: nil)
    }

    /// Sends the chat and answers its turn, or after `wait` what came so far (`ended` false), which goes on with its
    /// stream open, since closing it cancels the turn on the machine. The platform waits for the machine only
    /// `wait - 5 s` (`start_within_ms`), so a chat no machine took (an image without the relay, still booting) ends
    /// `machine_offline` and undelivered before this answers: the platform alone decides sent or not, with no race.
    public func answer(_ id: String, agent: String, prompt: String, cwd: String? = nil, promptID: String? = nil,
                       within wait: Duration) async throws -> Answer {
        let progress = Progress()
        let startWithin = max(wait - .seconds(5), .seconds(1))
        // task-owner: the turn's stream; it runs to the turn's end after this answers, since closing it cancels the turn.
        let turn = Task {
            try await chat(id, agent: agent, prompt: prompt, cwd: cwd, promptID: promptID, startWithin: startWithin, progress: progress)
        }
        if let answer = try await Self.first(turn, within: wait) { return answer }
        return await progress.answer
    }

    /// The turn's answer if it ends within `wait`, else nil (the turn goes on).
    static func first(_ turn: Task<Answer, any Error>, within wait: Duration) async throws -> Answer? {
        let (answers, continuation) = AsyncStream<Result<Answer, any Error>?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // task-owner: relays the turn's answer; it ends with the turn (a yield after finish is dropped).
        Task { continuation.yield(await turn.result) }
        // task-owner: the answer deadline; cancelled below once an answer is in.
        let deadline = Task {
            // wakeup-allow: one-shot answer deadline; cancelled when the turn answers first
            try? await Task.sleep(for: wait)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        for await answer in answers { return try answer?.get() }
        return nil
    }

    /// The chat's stream to its end. A refusal (any non-2xx: nothing was sent to the machine) is an undelivered
    /// answer, not a throw; only a failure before any response throws.
    func chat(_ id: String, agent: String, prompt: String, cwd: String?, promptID: String?, startWithin: Duration?,
              progress: Progress?) async throws -> Answer {
        guard Self.isMachineID(id) else { throw CloudAPIError.transport("not a Cloud machine id") }
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        let path = "/v1/cloud/machines/\(id)/chat"
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { throw CloudAPIError.transport("bad path \(path)") }
        var body: [String: Any] = ["agent": agent, "prompt": prompt]
        if let cwd { body["cwd"] = cwd }
        if let promptID { body["prompt_id"] = promptID }
        if let startWithin { body["start_within_ms"] = Int(startWithin / .milliseconds(1)) }
        // An idle limit, not a deadline: a turn may run for hours, and closing its stream would cancel it.
        var request = URLRequest(url: url, timeoutInterval: Self.idleTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let clock = ContinuousClock(), start = clock.now
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        var answer = Answer()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var data = Data()
            // The body only words the refusal: one cut short is no refusal text.
            do { for try await byte in bytes where data.count < 64 * 1024 { data.append(byte) } } catch { data.removeAll() }
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
            answer.errorCode = (error?["code"] as? String) ?? "cloud.relay.http_\(status)"
            answer.errorMessage = (error?["message"] as? String) ?? "the relay answered HTTP \(status)"
            answer.total = clock.now - start
            return answer
        }
        // Once the stream is open the prompt may be on the machine: a break answers what came, never a throw.
        var broken: String?
        do {
            for try await line in bytes.lines {
                answer.apply(line: line, at: clock.now - start)
                await progress?.set(answer)
                if answer.ended { break }
            }
        } catch {
            broken = error.localizedDescription
        }
        if !answer.ended {
            answer.broken = true
            answer.errorCode = "cloud.relay.closed"
            answer.errorMessage = broken.map { "the relay broke before the turn ended: \($0)" } ?? "the relay closed before the turn ended"
            answer.total = clock.now - start
            await progress?.set(answer)
        }
        return answer
    }
}

extension CloudAPIClient {
    /// The relay-first chat at `baseURL` (``CloudConfiguration/relayAPIBaseURL(environment:)``), as this
    /// client's person and team. Only a Worker machines client's: the classic client sends a Stack session
    /// the platform does not take.
    public func relayChat(baseURL: URL) -> CloudRelayChat? {
        guard !sendsStackSession else { return nil }
        let tokens = tokens
        // Not this client's session, which follows redirects: the relay's refuses them.
        return CloudRelayChat(baseURL: baseURL, accessToken: { try await tokens().0 }, teamID: teamID)
    }
}
