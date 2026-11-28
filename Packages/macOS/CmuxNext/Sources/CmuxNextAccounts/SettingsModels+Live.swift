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

/// The login Keychain, written by acpmux (`connections/secret.store`): the daemon adds the item through
/// the Security framework, so its access list trusts acpmux, which reads it at each request, and not
/// `/usr/bin/security`. (An item `security` creates trusts `security`, so any process of the user could
/// read it with `security find-generic-password -w` and no prompt.) The key goes only over acpmux's unix
/// socket. An acpmux too old for `secret.store` gets the earlier `security -i` write: the key on the
/// tool's standard input, never its arguments, its output (which can echo the line) dropped.
public struct KeychainModelKeyStore: ModelKeyStoring {
    public static let service = "cmux-model-key"

    private let environment: @Sendable @MainActor () async -> AcpmuxEnvironment?

    public init(environment: @escaping @Sendable @MainActor () async -> AcpmuxEnvironment?) {
        self.environment = environment
    }

    public func store(_ key: String, provider: String) async throws -> String {
        let account = "\(provider)-\(UUID().uuidString.lowercased().prefix(8))"
        let label = "cmux \(provider) API key"
        guard let environment = await environment() else {
            throw PageError(code: "cmux.page.unavailable", message: "no acpmux")
        }
        do {
            let reply = try JSONValue.parse(try await environment.harness(.connectionsSecretStore,
                                                                          params: ["account": account, "label": label, "secret": key]))
            guard let reference = reply["secret"]?.stringValue else {
                throw PageError(code: "cmux.models.keychain", message: "the key could not be stored in the Keychain")
            }
            return reference
        } catch let error as AcpmuxRPCError where error.isMethodMissing {
            return try await Self.storeWithSecurityTool(key, account: account, label: label)
        } catch let error as AcpmuxRPCError {
            throw PageError(code: "cmux.models.keychain", message: error.message)
        }
    }

    public func delete(_ reference: String) async {
        let prefix = "keychain:\(Self.service)/"
        guard reference.hasPrefix(prefix) else { return }
        let account = String(reference.dropFirst(prefix.count))
        guard !account.isEmpty, !account.contains("/") else { return }
        // acpmux deletes what it wrote, and an earlier `security` item with `security`.
        if let environment = await environment() {
            do {
                _ = try await environment.harness(.connectionsSecretDelete, params: ["account": account])
                return
            } catch let error as AcpmuxRPCError where !error.isMethodMissing && !error.isUnreachable {
                return
            } catch {}
        }
        _ = try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"),
                                                         ["delete-generic-password", "-s", Self.service, "-a", account],
                                                         errorOutput: .discard, timeout: .seconds(30)))
    }

    /// An acpmux without `secret.store`: the item through `security -i`, as before.
    private static func storeWithSecurityTool(_ key: String, account: String, label: String) async throws -> String {
        let line = "add-generic-password -U -s \(quoted(service)) -a \(quoted(account)) "
            + "-l \(quoted(label)) -w \(quoted(key))\n"
        let ran = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"), ["-i"],
                                                              input: Data(line.utf8), errorOutput: .discard, timeout: .seconds(30), onCancel: .finish))
        guard ran.succeeded else { throw PageError(code: "cmux.models.keychain", message: "the key could not be stored in the Keychain") }
        return "keychain:\(service)/\(account)"
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
        let environment = try await requireDaemonEnvironment()
        if let attempt = chatgptAttempt { await endAttempt(attempt, environment) }
        var params: [String: any Sendable] = [:]
        if let id, !id.isEmpty { params["id"] = id }
        let reply = try JSONValue.parse(try await daemon(environment, .chatgptBegin, params))
        // Only OpenAI's own sign-in page: the daemon's answer never opens anything else.
        guard let attempt = reply["attempt"]?.stringValue, !attempt.isEmpty,
              let url = reply["url"]?.stringValue.flatMap(URL.init(string:)), url.scheme == "https", url.host == "auth.openai.com",
              url.port == nil, url.user == nil, url.password == nil else {
            // An attempt it did start ends here, with its callback listener.
            if let attempt = reply["attempt"]?.stringValue, !attempt.isEmpty { await endAttempt(attempt, environment) }
            throw PageError(code: "cmux.models.chatgpt_bad_reply", message: "acpmux did not start a ChatGPT sign-in")
        }
        setChatGPT(attempt: attempt, error: nil)
        do {
            try await openSignIn(url, owner: "chatgpt:\(attempt)")
        } catch {
            await endAttempt(attempt, environment)
            finish(attempt, error: nil)
            throw error
        }
        guard chatgptAttempt == attempt else { return .object([:]) }
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
        if let environment = await environment() { await endAttempt(attempt, environment) }
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
        dismissSignInPage?("chatgpt:\(attempt)")
        if let error { onSignInFailed?("codex", error) }
    }

    /// Connect Claude in one click (Leo, 2026-11-25: no copy and paste at all): acpmux runs
    /// `claude setup-token` in its own PTY, never a visible terminal, and answers its sign-in page,
    /// which opens in the app's own browser; the token the run prints is captured by acpmux, stored in
    /// the Keychain and added as a reference, never shown or sent here. The wait loop is
    /// ``awaitChatGPT``'s; a code the page shows instead of returning goes in with ``claudeTokenCode``.
    func connectClaudeToken(label: String?) async throws -> JSONValue {
        let environment = try await requireDaemonEnvironment()
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
            do {
                try await openSignIn(url, owner: "claude-token:\(attempt)")
            } catch {
                await endClaudeToken(attempt, environment)
                finishClaudeToken(attempt, error: nil)
                throw error
            }
            guard claudeTokenAttempt == attempt else { return .object([:]) }
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
        url.scheme == "https" && url.port == nil && url.user == nil && url.password == nil
            && ["claude.ai", "console.anthropic.com", "platform.claude.com"].contains(url.host ?? "")
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
        _ = try await daemon(try await requireDaemonEnvironment(), .claudeTokenCode, ["attempt": attempt, "code": code])
    }

    func cancelClaudeToken() async {
        guard let attempt = claudeTokenAttempt else { return }
        replaceClaudeTokenTask(nil)
        finishClaudeToken(attempt, error: nil)
        if let environment = await environment() { await endClaudeToken(attempt, environment) }
    }

    private func endClaudeToken(_ attempt: String, _ environment: AcpmuxEnvironment) async {
        _ = try? await daemon(environment, .claudeTokenCancel, ["attempt": attempt])
    }

    private func finishClaudeToken(_ attempt: String, error: String?, saved: Bool = false) {
        guard claudeTokenAttempt == attempt else { return }
        setClaudeToken(attempt: nil, phase: nil, error: error, saved: saved)
        dismissSignInPage?("claude-token:\(attempt)")
        if let error { onSignInFailed?("claude", error) }
    }

    /// Save an API key in the Keychain and send its reference to the connection owner.
    /// A refused write removes the newly saved item.
    func addKey(provider: String, key: String, label: String?, replacing: (id: String, instance: String)?, servesCloud: Bool?, checkStoredKey: Bool) async throws {
        guard Self.providers.contains(provider) else { throw PageError.invalidParams("addKey needs a known provider") }
        let key = Self.withoutWhitespace(key)
        guard Self.isModelAPIKey(key) else { throw PageError.invalidParams("addKey needs a valid API key") }
        var params: [String: any Sendable] = ["provider": provider]
        if let replacing {
            params["replace"] = replacing.id
            params["replaceInstance"] = replacing.instance
        } else if let servesCloud {
            params["servesCloud"] = servesCloud
        }
        _ = try await addSecret(key, store: provider, method: .connectionsKeyAdd, params: params, label: label, checked: checkStoredKey)
    }

    /// Add a Claude setup token (`claude setup-token`'s `sk-ant-oat…`, pasted after the terminal tab ran
    /// it): into the Keychain first, then `connections/claude_token.add` with its reference only. Every
    /// whitespace character is taken out first (`withoutWhitespace`): a terminal that wrapped the token
    /// across lines or padded it with spaces still gives the one token it printed. What is left must
    /// read as a token (`isClaudeToken`).
    func addClaudeToken(_ token: String, label: String?, replacing: (id: String, instance: String)?) async throws {
        let token = Self.withoutWhitespace(token)
        guard Self.isClaudeToken(token) else {
            throw PageError.invalidParams("addClaudeToken needs the sk-ant-oat token claude setup-token printed")
        }
        let reply = try await addSecret(token, store: "claude-token", method: .claudeTokenAdd, params: [:], label: label)
        guard let replacing else { return }
        let changed = PageError.invalidParams("replacement needs both saved Claude token instances")
        guard let added = reply["added_connection"], let id = added["id"]?.stringValue,
              let instance = added["credential_instance"]?.stringValue, id != replacing.id else { throw changed }
        let rows = reply["connections"]?.arrayValue ?? []
        guard rows.contains(where: { $0["id"]?.stringValue == id && $0["credential_instance"]?.stringValue == instance }) else {
            throw changed
        }
        do {
            guard rows.contains(where: {
                $0["id"]?.stringValue == replacing.id && $0["credential_instance"]?.stringValue == replacing.instance
            }) else { throw changed }
            let ids = rows.compactMap { $0["id"]?.stringValue }.filter { $0 != id }
            // Move the new identity into position before removing the old connection.
            let order = ids.flatMap { $0 == replacing.id ? [id, $0] : [$0] }
            try await mutate(.connectionsOrderSet, ["ids": order])
        } catch {
            // The old connection was never removed. Undo the add where the daemon is reachable.
            try? await mutate(.connectionsRemove, ["id": id, "instance": instance])
            throw error
        }
        guard connections.contains(where: {
            $0["id"]?.stringValue == id && $0["credentialInstance"]?.stringValue == instance
        }) else { throw changed }
        try await mutate(.connectionsRemove, ["id": replacing.id, "instance": replacing.instance])
    }

    nonisolated static let claudeTokenPrefix = "sk-ant-oat"

    nonisolated static func isModelAPIKey(_ key: String) -> Bool {
        isOneWord(key) && !key.hasPrefix("sk-ant-oat")
    }

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
                           params base: [String: any Sendable], label: String?, checked: Bool = false) async throws -> JSONValue {
        let environment = try await requireDaemonEnvironment()
        let reference = try await storeKey(secret, provider: store)
        var params = base
        params["secret"] = reference
        if checked, let refusal = await keyRefusal(environment, params) {
            await deleteKey(reference)
            throw refusal
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { params["label"] = String(label.prefix(128)) }
        do {
            let reply = try JSONValue.parse(try await daemon(environment, method, params,
                                                           rollbackKeychainReference: reference))
            if reply["connections"] != nil { apply(reply) } else { await refresh() }
            if let previous = reply["replaced_secret"]?.stringValue { await deleteKey(previous) }
            return reply
        } catch {
            // A disconnected socket can lose a successful reply. Refresh the
            // route mirror and keep its Keychain item unless the daemon refused.
            await refresh()
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
