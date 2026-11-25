public import CmuxNextAgentPane
import CmuxNextPages
public import CmuxNextSettings
import CmuxNextWakeups
public import Foundation

/// Where a pasted model API key goes on this Mac: the Keychain, before acpmux hears of it. acpmux gets
/// only the returned reference (`keychain:SERVICE/ACCOUNT`) and resolves it itself at each request.
public protocol ModelKeyStoring: Sendable {
    /// Stores KEY for PROVIDER; answers its `keychain:` reference.
    func store(_ key: String, provider: String) async throws -> String
    /// Removes a stored key by its reference (a connection that was never added).
    func delete(_ reference: String) async
}

/// The login Keychain through `/usr/bin/security`, as acpmux's own `cmux harness secret set` stores
/// one (cli/harness_secret.rs): the item's creator is `security`, so acpmux's
/// `security find-generic-password` reads it without a prompt. The key goes only to the tool's
/// standard input (`security -i`), never its arguments, and its output (which can echo the line) is
/// dropped.
public struct KeychainModelKeyStore: ModelKeyStoring {
    public static let service = "cmux-model-key"

    public init() {}

    public func store(_ key: String, provider: String) async throws -> String {
        let account = "\(provider)-\(UUID().uuidString.lowercased().prefix(8))"
        let line = "add-generic-password -U -s \(Self.quoted(Self.service)) -a \(Self.quoted(account)) "
            + "-l \(Self.quoted("cmux \(provider) API key")) -w \(Self.quoted(key))\n"
        let ran = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"), ["-i"],
                                                              input: Data(line.utf8), errorOutput: .discard, timeout: .seconds(30), onCancel: .finish))
        guard ran.succeeded else { throw PageError(code: "cmux.models.keychain", message: "the key could not be stored in the Keychain") }
        return "keychain:\(Self.service)/\(account)"
    }

    public func delete(_ reference: String) async {
        let prefix = "keychain:\(Self.service)/"
        guard reference.hasPrefix(prefix) else { return }
        let account = String(reference.dropFirst(prefix.count))
        guard !account.isEmpty, !account.contains("/") else { return }
        _ = try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"),
                                                         ["delete-generic-password", "-s", Self.service, "-a", account],
                                                         errorOutput: .discard, timeout: .seconds(30)))
    }

    /// One `security -i` word: quoted, with `\` and `"` escaped.
    nonisolated static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension SettingsModels {
    /// Continue with ChatGPT: acpmux starts the attempt and its callback listener, OpenAI's sign-in page
    /// opens in cmux's own browser (the person's when there is none), and acpmux's answer is awaited off the main thread
    /// (`chatgpt.wait`, a long poll the loop calls again while pending). `id`: an existing
    /// chatgpt-plan connection to sign in again.
    func connectChatGPT(id: String?) async throws -> JSONValue {
        let environment = try requireDaemonEnvironment()
        if let attempt = chatgptAttempt { await endAttempt(attempt, environment) }
        var params: [String: any Sendable] = [:]
        if let id, !id.isEmpty { params["id"] = id }
        let reply = try JSONValue.parse(try await daemon(environment, .chatgptBegin, params))
        // Only OpenAI's own sign-in page: the daemon's answer never opens anything else.
        guard let attempt = reply["attempt"]?.stringValue, !attempt.isEmpty,
              let url = reply["url"]?.stringValue.flatMap(URL.init(string:)), url.scheme == "https", url.host == "auth.openai.com" else {
            // An attempt it did start ends here, with its callback listener.
            if let attempt = reply["attempt"]?.stringValue, !attempt.isEmpty { await endAttempt(attempt, environment) }
            throw PageError(code: "cmux.models.chatgpt_bad_reply", message: "acpmux did not start a ChatGPT sign-in")
        }
        setChatGPT(attempt: attempt, error: nil)
        await openInAppSignIn(url)
        // task-owner: SettingsModels.chatgptTask: one attempt's wait loop; a new attempt or Cancel replaces it.
        replaceChatGPTTask(Task { [weak self] in await self?.awaitChatGPT(attempt, environment) })
        return ["attempt": .string(attempt)]
    }

    /// The wait loop: pending asks again; done reads the connections; failed shows its error. acpmux's
    /// own refusal (`chatgpt.unknown_attempt`, ...) ends it at once with that code; a daemon that does
    /// not answer ends it after ``chatgptFailures`` calls in a row. Either way the attempt is cancelled,
    /// so acpmux's loopback listener closes.
    func awaitChatGPT(_ attempt: String, _ environment: AcpmuxEnvironment) async {
        var failures = 0
        // wakeup-allow: each round awaits acpmux's long poll (up to 25 s); chatgptRounds bounds the attempt
        for _ in 0..<Self.chatgptRounds {
            guard !Task.isCancelled, chatgptAttempt == attempt else { return }
            let reply: JSONValue
            do {
                reply = try JSONValue.parse(try await daemon(environment, .chatgptWait, ["attempt": attempt]))
                failures = 0
            } catch {
                let refusal = Self.daemonRefusal(error)
                failures += 1
                guard refusal != nil || failures >= Self.chatgptFailures else { continue }
                guard chatgptAttempt == attempt else { return }
                await endAttempt(attempt, environment)
                return finish(attempt, error: refusal ?? "unreachable")
            }
            guard chatgptAttempt == attempt else { return }
            switch reply["status"]?.stringValue {
            case "pending":
                continue
            case "done":
                finish(attempt, error: nil)
                await refresh()
                return
            case "cancelled":
                return finish(attempt, error: nil)
            default:
                return finish(attempt, error: reply["error"]?.stringValue ?? "failed")
            }
        }
        await endAttempt(attempt, environment)
        finish(attempt, error: "timed_out")
    }

    func cancelChatGPT() async {
        guard let attempt = chatgptAttempt else { return }
        replaceChatGPTTask(nil)
        finish(attempt, error: nil)
        if let environment = environment() { await endAttempt(attempt, environment) }
    }

    /// acpmux's own error name (`chatgpt.unknown_attempt`) for a call it answered with an error; nil when
    /// it did not answer (socket, timeout).
    nonisolated static func daemonRefusal(_ error: any Error) -> String? {
        guard let error = error as? PageError, error.code.hasPrefix("cmux.models.") else { return nil }
        return String(error.code.dropFirst("cmux.models.".count))
    }

    private func endAttempt(_ attempt: String, _ environment: AcpmuxEnvironment) async {
        _ = try? await daemon(environment, .chatgptCancel, ["attempt": attempt])
    }

    private func finish(_ attempt: String, error: String?) {
        guard chatgptAttempt == attempt else { return }
        setChatGPT(attempt: nil, error: error)
    }

    /// Connect Claude in one click (Leo, 2026-11-25: no copy and paste at all): acpmux runs
    /// `claude setup-token` in its own PTY, never a visible terminal, and answers its sign-in page,
    /// which opens in the app's own browser; the token the run prints is captured by acpmux, stored in
    /// the Keychain and added as a reference, never shown or sent here. The wait loop is
    /// ``awaitChatGPT``'s; a code the page shows instead of returning goes in with ``claudeTokenCode``.
    func connectClaudeToken(label: String?) async throws -> JSONValue {
        let environment = try requireDaemonEnvironment()
        if let attempt = claudeTokenAttempt { await endClaudeToken(attempt, environment) }
        setClaudeToken(attempt: nil, phase: "starting", error: nil)
        var params: [String: any Sendable] = [:]
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { params["label"] = label }
        let reply: JSONValue
        do { reply = try JSONValue.parse(try await daemon(environment, .claudeTokenBegin, params)) } catch {
            setClaudeToken(attempt: nil, phase: nil, error: Self.daemonRefusal(error) ?? "unreachable")
            throw error
        }
        // Only Claude's own sign-in page: the daemon's answer never opens anything else. No link at all
        // (`url: null`) is a run that printed its token straight away (a claude.ai session it already
        // had): nothing to open, the wait below sees it saved.
        let link = reply["url"]?.stringValue
        let url = link.flatMap(URL.init(string:))
        guard let attempt = reply["attempt"]?.stringValue, !attempt.isEmpty,
              link == nil || url.map(Self.isClaudeSignInPage) == true else {
            if let attempt = reply["attempt"]?.stringValue, !attempt.isEmpty { await endClaudeToken(attempt, environment) }
            setClaudeToken(attempt: nil, phase: nil, error: "claude_token.bad_reply")
            throw PageError(code: "cmux.models.claude_token_bad_reply", message: "acpmux did not start a Claude sign-in")
        }
        if let url {
            setClaudeToken(attempt: attempt, phase: "signing_in", error: nil)
            await openInAppSignIn(url)
        } else {
            setClaudeToken(attempt: attempt, phase: "saving", error: nil)
        }
        // task-owner: SettingsModels.claudeTokenTask: one attempt's wait loop; a new attempt or Cancel replaces it.
        replaceClaudeTokenTask(Task { [weak self] in await self?.awaitClaudeToken(attempt, environment) })
        return ["attempt": .string(attempt)]
    }

    /// The Cloud chat's Set up Cloud button in place (`cloud.setUp`, whose click the pane already took):
    /// `setUpClaude` runs Claude's one-click connection, `connectChatGPT` Continue with ChatGPT, and the
    /// chat starts once the connection shows (``onConnections``). False when this Mac's acpmux cannot
    /// (an older daemon, no daemon): the caller opens Settings > Cloud instead, as before.
    public func connectInPlace(_ action: String) async -> Bool {
        do {
            switch action {
            case "setUpClaude": _ = try await connectClaudeToken(label: nil)
            case "connectChatGPT": _ = try await connectChatGPT(id: nil)
            default: return false
            }
            return true
        } catch {
            return false
        }
    }

    /// `https://claude.ai/...` or `https://console.anthropic.com/...`: the pages `claude setup-token` signs in on.
    nonisolated static func isClaudeSignInPage(_ url: URL) -> Bool {
        url.scheme == "https" && ["claude.ai", "console.anthropic.com", "platform.claude.com"].contains(url.host ?? "")
    }

    func awaitClaudeToken(_ attempt: String, _ environment: AcpmuxEnvironment) async {
        var failures = 0
        // wakeup-allow: each round awaits acpmux's long poll (up to 25 s); chatgptRounds bounds the attempt
        for _ in 0..<Self.chatgptRounds {
            guard !Task.isCancelled, claudeTokenAttempt == attempt else { return }
            let reply: JSONValue
            do {
                reply = try JSONValue.parse(try await daemon(environment, .claudeTokenWait, ["attempt": attempt]))
                failures = 0
            } catch {
                let refusal = Self.daemonRefusal(error)
                failures += 1
                guard refusal != nil || failures >= Self.chatgptFailures else { continue }
                guard claudeTokenAttempt == attempt else { return }
                await endClaudeToken(attempt, environment)
                return finishClaudeToken(attempt, error: refusal ?? "unreachable")
            }
            guard claudeTokenAttempt == attempt else { return }
            switch reply["status"]?.stringValue {
            case "pending":
                continue
            case "done":
                setClaudeToken(attempt: attempt, phase: "saving", error: nil)
                await refresh()
                return finishClaudeToken(attempt, error: nil, saved: true)
            case "cancelled":
                return finishClaudeToken(attempt, error: nil)
            default:
                return finishClaudeToken(attempt, error: reply["error"]?.stringValue ?? "failed")
            }
        }
        await endClaudeToken(attempt, environment)
        finishClaudeToken(attempt, error: "timed_out")
    }

    /// The code Claude's page showed (when it did not return to the run on its own), typed into the run.
    func claudeTokenCode(_ code: String) async throws {
        let code = Self.withoutWhitespace(code)
        guard let attempt = claudeTokenAttempt else { throw PageError.invalidParams("claudeTokenCode needs a Claude sign-in in progress") }
        guard !code.isEmpty, code.utf8.count <= 4096 else { throw PageError.invalidParams("claudeTokenCode needs the code Claude showed") }
        _ = try await daemon(try requireDaemonEnvironment(), .claudeTokenCode, ["attempt": attempt, "code": code])
    }

    func cancelClaudeToken() async {
        guard let attempt = claudeTokenAttempt else { return }
        replaceClaudeTokenTask(nil)
        finishClaudeToken(attempt, error: nil)
        if let environment = environment() { await endClaudeToken(attempt, environment) }
    }

    private func endClaudeToken(_ attempt: String, _ environment: AcpmuxEnvironment) async {
        _ = try? await daemon(environment, .claudeTokenCancel, ["attempt": attempt])
    }

    private func finishClaudeToken(_ attempt: String, error: String?, saved: Bool = false) {
        guard claudeTokenAttempt == attempt else { return }
        setClaudeToken(attempt: nil, phase: nil, error: error, saved: saved)
    }

    /// Add an API key: every whitespace character out first (`withoutWhitespace`: a key a page or terminal
    /// wrapped across lines is still the one key), into the Keychain, then acpmux checks it with the
    /// provider (`connections/key.check`, by reference) and `connections/key.add` saves the reference.
    /// A key the provider refuses, or of another provider's shape, is taken back out and said
    /// (`cmux.models.key_rejected`, acpmux's sentence); a provider that does not answer saves anyway.
    func addKey(provider: String, key: String, label: String?) async throws {
        guard Self.providers.contains(provider) else { throw PageError.invalidParams("addKey needs a known provider") }
        let key = Self.withoutWhitespace(key)
        guard Self.isOneWord(key) else { throw PageError.invalidParams("addKey needs a key of printable characters") }
        try await addSecret(key, store: provider, method: .connectionsKeyAdd, params: ["provider": provider], label: label, checked: true)
    }

    /// Add a Claude setup token (`claude setup-token`'s `sk-ant-oat…`, pasted after the terminal tab ran
    /// it): into the Keychain first, then `connections/claude_token.add` with its reference only. Every
    /// whitespace character is taken out first (`withoutWhitespace`): a terminal that wrapped the token
    /// across lines or padded it with spaces still gives the one token it printed. What is left must
    /// read as a token (`isClaudeToken`).
    func addClaudeToken(_ token: String, label: String?) async throws {
        let token = Self.withoutWhitespace(token)
        guard Self.isClaudeToken(token) else {
            throw PageError.invalidParams("addClaudeToken needs the sk-ant-oat token claude setup-token printed")
        }
        try await addSecret(token, store: "claude-token", method: .claudeTokenAdd, params: [:], label: label)
    }

    nonisolated static let claudeTokenPrefix = "sk-ant-oat"

    /// TOKEN with every space, tab, line break and invisible space (zero-width, BOM) taken out. A setup
    /// token never holds whitespace, so a pasted one loses only what the copy added.
    nonisolated static func withoutWhitespace(_ secret: String) -> String {
        String(String.UnicodeScalarView(secret.unicodeScalars.filter { scalar in
            !scalar.properties.isWhitespace && !invisibleSpaces.contains(scalar.value)
        }))
    }

    /// Zero-width space, non-joiner, joiner, word joiner and BOM: not whitespace to Unicode, but a paste adds them.
    nonisolated private static let invisibleSpaces: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]

    /// Whether TOKEN reads as a Claude setup token: `sk-ant-oat`, two digits, a dash, then base64url
    /// (letters, digits, `-`, `_`), as webviews' `claudeSetupToken.ts` checks it.
    nonisolated static func isClaudeToken(_ token: String) -> Bool {
        guard token.hasPrefix(claudeTokenPrefix), token.utf8.count <= keyLimit else { return false }
        let rest = Array(token.utf8.dropFirst(claudeTokenPrefix.utf8.count))
        guard rest.count > 3, rest[0] >= 0x30, rest[0] <= 0x39, rest[1] >= 0x30, rest[1] <= 0x39, rest[2] == 0x2D else { return false }
        return rest.dropFirst(3).allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// One line of printable characters with no spaces, as a key or token is; the Keychain line must not break.
    nonisolated static func isOneWord(_ secret: String) -> Bool {
        !secret.isEmpty && secret.utf8.count <= keyLimit && secret.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
    }

    /// SECRET into the Keychain (as STORE), then METHOD with its reference only; a refused add takes it back out.
    private func addSecret(_ secret: String, store: String, method: AcpmuxHarnessMethod,
                           params base: [String: any Sendable], label: String?, checked: Bool = false) async throws {
        let environment = try requireDaemonEnvironment()
        let reference = try await storeKey(secret, provider: store)
        var params = base
        params["secret"] = reference
        if checked, let refusal = await keyRefusal(environment, params) {
            await deleteKey(reference)
            throw refusal
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { params["label"] = String(label.prefix(128)) }
        do {
            let reply = try JSONValue.parse(try await daemon(environment, method, params))
            if reply["connections"] != nil { apply(reply) } else { await refresh() }
        } catch {
            await deleteKey(reference)
            throw error
        }
    }

    /// acpmux's `key.check` answer for a stored key: the refusal to show when the provider refused it or
    /// it is another provider's shape; nil when it saves (ok, unreachable, or a daemon without the check).
    private func keyRefusal(_ environment: AcpmuxEnvironment, _ params: [String: any Sendable]) async -> PageError? {
        guard let data = try? await daemon(environment, .connectionsKeyCheck, params),
              let reply = try? JSONValue.parse(data), reply["save"] == .bool(false) else { return nil }
        return PageError(code: "cmux.models.key_rejected", message: reply["message"]?.stringValue ?? "Key rejected by the provider")
    }

    /// The team's shared key for an agent: `key` sets or replaces it, nil removes it (owners and admins).
    func orgKey(agent: String, key: String?, kind: String?) async throws {
        guard TeamAgentKeys.agents.contains(agent) else { throw PageError.invalidParams("orgKey needs claude or codex") }
        guard let keys = teamAgentKeys, hasTeam else { throw PageError.unavailable("no team") }
        // The team's keys answer nothing for a change they skip: say why here.
        guard keys.canManage else { throw PageError(code: "cmux.models.auth.forbidden", message: TeamAgentKeys.copy("auth.forbidden")) }
        guard !keys.busy else { throw PageError(code: "cmux.models.busy", message: "another change to the team's keys is still running") }
        if let key {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            await keys.save(agent: agent, kind: kind.flatMap { TeamAgentKeys.kinds.contains($0) ? $0 : nil } ?? Self.kind(of: trimmed), secret: trimmed)
        } else {
            await keys.remove(agent: agent)
        }
        if let code = keys.currentProblem?.code { throw PageError(code: "cmux.models.\(code)", message: TeamAgentKeys.copy(code)) }
    }

    /// A Claude setup token (`sk-ant-oat…`) or a sign-in file is a subscription; anything else an API key.
    nonisolated static func kind(of key: String) -> String {
        key.hasPrefix("sk-ant-oat") || key.hasPrefix("{") ? "oauth" : "api_key"
    }
}

extension SettingsHarnesses {
    /// Settings > Models' Sign in to Claude: the Claude account sign-in Settings > Agents runs. The CLI's
    /// own login when it is signed out, else a new Claude account in a login folder of its own.
    func connectClaude(context: PageCallContext?) async throws {
        if accounts == nil, let environment = environment() { await readAccounts(environment, generation: generation) }
        if let login = accounts?.first(where: { $0.family == "claude" && $0.builtin }), !login.signedIn {
            _ = try await run(["action": "accountSignIn", "account": .string(login.id)], context: context)
        } else {
            _ = try await run(["action": "accountAdd", "family": "claude"], context: context)
        }
    }
}
