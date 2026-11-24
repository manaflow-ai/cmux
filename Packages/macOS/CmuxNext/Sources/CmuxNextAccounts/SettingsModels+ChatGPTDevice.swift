import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

enum ModelDeviceProvider: String {
    case chatgpt, grok, copilot, kimi, openrouter

    var connectionKind: String { "\(rawValue)-plan" }
    var begin: AcpmuxHarnessMethod { self == .chatgpt ? .chatgptDeviceBegin : .subscriptionDeviceBegin }
    var wait: AcpmuxHarnessMethod { self == .chatgpt ? .chatgptDeviceWait : .subscriptionDeviceWait }
    var cancel: AcpmuxHarnessMethod { self == .chatgpt ? .chatgptDeviceCancel : .subscriptionDeviceCancel }

    func admits(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil else { return false }
        switch self {
        case .chatgpt: return url.absoluteString == "https://auth.openai.com/codex/device"
        case .grok: return ["accounts.x.ai", "auth.x.ai", "grok.com", "www.grok.com", "x.ai"].contains(url.host ?? "")
        case .copilot: return url.host == "github.com" && url.path == "/login/device"
        case .kimi: return ["kimi.com", "www.kimi.com", "auth.kimi.com", "kimi.ai", "www.kimi.ai", "auth.kimi.ai"].contains(url.host ?? "")
        case .openrouter: return url.host == "openrouter.ai" && url.path == "/auth"
        }
    }
}

enum ChatGPTDeviceState: Equatable {
    struct Challenge: Equatable {
        let attempt: String
        let code: String
        let url: URL
        let expiresAt: Int

        var pageURL: String {
            guard !code.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
            components.query = nil
            components.fragment = nil
            return components.string ?? ""
        }
    }

    case idle, starting, showingChallenge(Challenge), cancelling, connected(String), failed(String)
    case wrongAccount(actual: String, expected: String)

    var pageState: JSONValue {
        switch self {
        case .idle: ["phase": "idle"]
        case .starting: ["phase": "starting"]
        case .showingChallenge(let challenge):
            ["phase": "waiting", "userCode": .string(challenge.code), "expiresAt": JSONValue(challenge.expiresAt),
             "verificationURL": .string(challenge.pageURL)]
        case .cancelling: ["phase": "cancelling"]
        case .connected(let id): ["phase": "connected", "id": .string(id)]
        case .failed(let error): ["phase": "failed", "error": .string(error)]
        case .wrongAccount(let actual, let expected):
            ["phase": "failed", "error": "different_account", "actual": .string(actual), "expected": .string(expected)]
        }
    }
}

extension SettingsModels {
    /// A person's click starts one device attempt and authorizes its follow-up waits.
    func connectChatGPTDevice(
        replacing id: String?, openBrowser: Bool, provider: ModelDeviceProvider = .chatgpt,
        region: String? = nil, servesCloud: Bool? = nil
    ) {
        guard chatgptDeviceTask == nil, chatgptDevice != .cancelling else { return }
        let runID = UUID()
        deviceProvider = provider
        deviceRegion = provider == .kimi ? region : nil
        deviceTarget = id
        chatgptDeviceRunID = runID
        chatgptDevice = .starting
        // task-owner: SettingsModels.chatgptDeviceTask owns the daemon attempt until it ends.
        chatgptDeviceTask = Task { [weak self] in
            await self?.runChatGPTDevice(replacing: id, runID: runID, openBrowser: openBrowser, provider: provider,
                                         region: region, servesCloud: servesCloud)
        }
    }

    func cancelChatGPTDevice() async {
        switch chatgptDevice {
        case .starting:
            // The begin reply may still be in flight. Its task cancels as soon as it has the ID.
            chatgptDevice = .cancelling
        case .showingChallenge(let challenge):
            guard let environment = chatgptDeviceEnvironment else { return }
            dismissSignInPage?("device:\(chatgptDeviceRunID)")
            chatgptDevice = .cancelling
            let next: ChatGPTDeviceState
            do {
                let reply = try await callChatGPTDevice(environment, deviceProvider.cancel, ["attempt": challenge.attempt])
                if reply["status"]?.stringValue == "done" { await refresh() }
                next = reply["connection_id"]?.stringValue.map(ChatGPTDeviceState.connected) ?? .idle
            } catch {
                next = .failed(Self.chatGPTDeviceError(error))
            }
            // A wait reply can arrive after the cancel reply. A new attempt can start now.
            chatgptDeviceRunID = UUID()
            chatgptDeviceTask?.cancel()
            chatgptDeviceTask = nil
            chatgptDeviceEnvironment = nil
            chatgptDevice = next
        case .idle, .cancelling, .connected, .failed, .wrongAccount:
            break
        }
    }

    private func runChatGPTDevice(
        replacing id: String?, runID: UUID, openBrowser: Bool, provider: ModelDeviceProvider,
        region: String?, servesCloud: Bool?
    ) async {
        let browserOwner = "device:\(runID)"
        var attempt: String?
        var shown: ChatGPTDeviceState?
        defer {
            dismissSignInPage?(browserOwner)
            if chatgptDeviceRunID == runID {
                chatgptDeviceEnvironment = nil
                chatgptDeviceTask = nil
            }
        }
        do {
            let environment = try await requireDaemonEnvironment()
            chatgptDeviceEnvironment = environment
            if chatgptDevice == .cancelling {
                chatgptDevice = .idle
                return
            }
            var params: [String: any Sendable] = [:]
            if let id { params["id"] = id }
            if provider != .chatgpt { params["provider"] = provider.rawValue }
            if provider == .kimi, let region { params["region"] = region }
            if provider == .openrouter, let servesCloud { params["servesCloud"] = servesCloud }
            let reply = try await callChatGPTDevice(environment, provider.begin, params)
            attempt = reply["attempt"]?.stringValue
            guard let attempt, !attempt.isEmpty else { throw PageError.invalidParams("missing sign-in attempt") }
            if chatgptDevice == .cancelling {
                _ = try await callChatGPTDevice(environment, provider.cancel, ["attempt": attempt])
                chatgptDevice = .idle
                return
            }
            let code = reply["user_code"]?.stringValue ?? ""
            guard provider == .openrouter || !code.isEmpty,
                  let expiresAt = reply["expires_at"]?.intValue,
                  let url = reply["verification_url"]?.stringValue.flatMap(URL.init(string:)),
                  provider.admits(url) else {
                throw PageError.invalidParams("invalid device challenge")
            }
            let presented = ChatGPTDeviceState.showingChallenge(.init(attempt: attempt, code: code, url: url, expiresAt: expiresAt))
            shown = presented
            chatgptDevice = presented
            if openBrowser, Double(expiresAt) > Date.now.timeIntervalSince1970 {
                try await openSignIn(url, owner: browserOwner)
            }
            // wakeup-allow: waits are daemon long polls bounded by the device attempt's expiry.
            for _ in 0...([.grok, .kimi].contains(provider) ? Self.chatgptRounds * 2 : Self.chatgptRounds) {
                guard chatgptDeviceRunID == runID, chatgptDevice == presented else { return }
                let reply = try await callChatGPTDevice(environment, provider.wait, ["attempt": attempt])
                guard chatgptDeviceRunID == runID, chatgptDevice == presented else { return }
                switch reply["status"]?.stringValue {
                case "pending": continue
                case "done":
                    await refresh()
                    if chatgptDeviceRunID == runID, chatgptDevice == presented {
                        chatgptDevice = (reply["connection_id"]?.stringValue ?? reply["connection"]?["id"]?.stringValue).map(ChatGPTDeviceState.connected) ?? .idle
                    }
                case "cancelled": chatgptDevice = .idle
                default:
                    if reply["error"]?.stringValue == "different_account",
                       let actual = reply["actual"]?.stringValue, let expected = reply["expected"]?.stringValue {
                        chatgptDevice = .wrongAccount(actual: actual, expected: expected)
                    } else {
                        chatgptDevice = .failed(Self.chatGPTDeviceErrorCode(reply["error"]?.stringValue))
                    }
                }
                return
            }
            _ = try await callChatGPTDevice(environment, provider.cancel, ["attempt": attempt])
            if chatgptDeviceRunID == runID, chatgptDevice == presented { chatgptDevice = .failed("expired_token") }
        } catch {
            // Once the code was shown, the Cancel gesture owns its final state.
            guard chatgptDeviceRunID == runID else { return }
            if let shown, chatgptDevice != shown { return }
            if let attempt, let environment = chatgptDeviceEnvironment {
                _ = try? await callChatGPTDevice(environment, provider.cancel, ["attempt": attempt])
            }
            guard chatgptDeviceRunID == runID else { return }
            if let shown, chatgptDevice != shown { return }
            chatgptDevice = chatgptDevice == .cancelling && attempt == nil ? .idle : .failed(Self.chatGPTDeviceError(error))
        }
    }

    private func callChatGPTDevice(
        _ environment: AcpmuxEnvironment, _ method: AcpmuxHarnessMethod, _ params: [String: any Sendable]
    ) async throws -> JSONValue {
        if hasDaemonOverride { return try JSONValue.parse(try await daemon(environment, method, params)) }
        guard let line = await AcpmuxPersonLine.open(environment, deadline: .seconds(40)) else {
            throw PageError(code: "cmux.models.chatgpt.network", message: "Sign-in needs a connection")
        }
        defer { line.close() }
        guard line.isPerson else { throw PageError.unavailable("Sign-in is unavailable") }
        guard let reply = await line.call(method.rawValue, params) else {
            throw PageError(code: "cmux.models.\(line.lastErrorReason ?? "chatgpt.network")", message: "Sign-in did not complete")
        }
        guard let value = JSONValue(foundation: reply) else { throw PageError.invalidParams("invalid sign-in reply") }
        return value
    }

    private nonisolated static func chatGPTDeviceError(_ error: any Error) -> String {
        let code = daemonRefusal(error)?.split(separator: ".").last.map(String.init)
        if (error as? PageError)?.code == "cmux.page.unavailable" { return "network" }
        return chatGPTDeviceErrorCode(code)
    }

    private nonisolated static func chatGPTDeviceErrorCode(_ code: String?) -> String {
        switch code {
        case "expired_token", "access_denied", "network", "already_signed_in", "no_chatgpt_account", "no_copilot_access", "keychain_locked", "keychain_other_build", "different_account", "storage", "port_busy", "enterprise_server":
            code ?? "failed"
        case "unreachable": "network"
        default: "failed"
        }
    }
}
