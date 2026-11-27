import Foundation

/// A bounded Add account form, forwarded unchanged to the daemon's existing local route writer.
/// Rust owns route kinds, credential-reference validation and defaults; replacement is never offered.
/// A Claude setup token (`kind: claude-token`, cmux#59852) is the one exception: the page sends the
/// token itself, which is checked here, put in the Keychain and handed to acpmux by reference only
/// (`_acpmux/connections/claude_token.add`), as Settings > Models adds one.
public nonisolated struct AgentPaneAddAccount: Equatable, Sendable {
    /// The kind of a Claude setup token's account (acpmux `RouteKind::ClaudeToken`).
    static let claudeTokenKind = "claude-token"

    public let id: String
    public let kind: String
    public let family: String
    public let fields: [String: String]
    /// A Codex login in a shadow home of the CLI's own (`shadow: true` on `_acpmux/route/add`).
    public let shadow: Bool

    init?(params: [String: Any]?) {
        let allowed: Set<String> = ["id", "kind", "family", "name", "accountHome", "secret", "shadow"]
        guard var params, Set(params.keys).isSubset(of: allowed) else { return nil }
        let shadow = params.removeValue(forKey: "shadow")
        guard shadow == nil || shadow is Bool,
              let fields = params as? [String: String],
              let id = fields["id"], !id.isEmpty, id.utf8.count <= 128,
              let kind = fields["kind"], !kind.isEmpty, kind.utf8.count <= 128,
              let family = fields["family"], !family.isEmpty, family.utf8.count <= 128,
              fields.values.allSatisfy({ $0.utf8.count <= 4096 }) else { return nil }
        self.id = id
        self.kind = kind
        self.family = family
        self.shadow = shadow as? Bool ?? false
        self.fields = fields.merging(Self.expandedHome(fields["accountHome"])) { _, home in home }
    }

    /// The page offers a new login a folder of its own as `~/.cmux/accounts/<id>`: it knows no home
    /// path, and the daemon takes only an absolute one. Anything else goes through as written.
    static func expandedHome(_ home: String?, homeDirectory: String = NSHomeDirectory()) -> [String: String] {
        guard let home, home.hasPrefix("~/"), home.count > 2 else { return [:] }
        return ["accountHome": (homeDirectory as NSString).appendingPathComponent(String(home.dropFirst(2)))]
    }

    @MainActor
    func reply(in model: AgentPaneModel, keys: any ModelKeyStoring = KeychainModelKeyStore()) async -> [String: Any] {
        guard !model.remoteChat else { return AgentPaneModel.unsupported("account.add") }
        // The App records native input; no parameter supplied by the page can grant this.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard let socket = model.transport.acpmuxSocket else { return AgentPaneModel.transportFailure(.noConnection) }
        if kind == Self.claudeTokenKind { return await addClaudeToken(socket: socket, keys: keys) }
        do {
            var params: [String: any Sendable] = ["families": [family]]
            for (key, value) in fields where key != "family" { params[key] = value }
            if shadow { params["shadow"] = true }
            let value = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/route/add",
                                                          params: params, deadline: .seconds(20), detailed: true)
            return AgentPaneReply.success(value)
        } catch let error as AcpmuxRPCError {
            return AgentPaneReply.failure(code: "account.failed", message: error.message)
        } catch AcpmuxStatusClient.Failure.rpc(let message) {
            return AgentPaneReply.failure(code: "account.failed", message: message)
        } catch {
            return AgentPaneModel.transportFailure(.noConnection)
        }
    }

    /// The token with all whitespace out (a terminal's wrap, padding, a zero-width space a copy added),
    /// refused with a sentence the dialog shows when it is not `claude setup-token`'s; then into the
    /// Keychain, and acpmux gets the reference with the account's name as its label. A refused add
    /// takes the Keychain item back out.
    @MainActor
    private func addClaudeToken(socket: String, keys: any ModelKeyStoring) async -> [String: Any] {
        guard family == "claude" else {
            return AgentPaneReply.failure(code: "account.failed", message: "A Claude setup token signs in Claude only.")
        }
        let token = ClaudeSetupToken.withoutWhitespace(fields["secret"] ?? "")
        guard ClaudeSetupToken.isValid(token) else {
            return AgentPaneReply.failure(code: "account.failed", message: Self.notAToken)
        }
        let reference: String
        do { reference = try await keys.store(token, provider: Self.claudeTokenKind) } catch {
            return AgentPaneReply.failure(code: "account.failed", message: "The token could not be stored in the Keychain.")
        }
        var params: [String: any Sendable] = ["secret": reference]
        if let name = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            params["label"] = String(name.prefix(128))
        }
        do {
            let value = try await AcpmuxStatusClient.call(socketPath: socket, method: AcpmuxHarnessMethod.claudeTokenAdd.rawValue,
                                                          params: params, deadline: .seconds(20), detailed: true)
            return AgentPaneReply.success(value)
        } catch let error as AcpmuxRPCError {
            await keys.delete(reference)
            return AgentPaneReply.failure(code: "account.failed", message: error.message)
        } catch AcpmuxStatusClient.Failure.rpc(let message) {
            await keys.delete(reference)
            return AgentPaneReply.failure(code: "account.failed", message: message)
        } catch {
            await keys.delete(reference)
            return AgentPaneModel.transportFailure(.noConnection)
        }
    }

    static let notAToken = "That is not a Claude setup token. Run claude setup-token in a terminal and paste the sk-ant-oat token it prints."
}
