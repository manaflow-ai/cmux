public import AppKit
public import CmuxNextDaemon
public import CmuxNextDesign
import SwiftUI

/// The Automations page as the app shows it (docs/automations-platonic-ideal.md section 8, option A):
/// one ``AutomationsPage`` model per app over both sources, and one hosted view per tab or top page.
///
/// The app passes the sources; nothing here knows the CLI or the network:
///
/// ```swift
/// let host = AutomationsPageHost(
///     local: { try await ProcessRunner.run(executable: cli, arguments: ["--json", "automation", "list"], …).stdout },
///     cloud: { try AutomationsPageHost.cloudValue(await relay.forward(listRequest)) })
/// let view = host.makeView(tokens: { window.themeScope.tokens })
/// ```
@MainActor
public final class AutomationsPageHost {
    /// Why a source gave no rows.
    public struct SourceError: Error, Equatable, CustomStringConvertible {
        /// The refusal code (`automation.signed_out`, `feature.disabled`), or `bad_reply`.
        public let code: String
        /// Words for a person.
        public let message: String
        /// Makes the error.
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
        public var description: String { message.isEmpty ? code : message }
    }

    /// The one model every view of the page shows.
    public let model: AutomationsPage
    /// Starts the cmux sign-in: the page's Sign In beside its signed-out Cloud line. Nil shows no button.
    public var signIn: (@MainActor @Sendable () -> Void)?
    /// Opens a prompt run's agent chat by its session name, with a title. Nil shows no Open chat.
    public var openChat: (@MainActor @Sendable (_ session: String, _ title: String) -> Void)?

    /// Makes the host.
    ///
    /// - Parameters:
    ///   - local: This Mac's `cmux automation list --json` output.
    ///   - cloud: The `value` of a Cloud `automation.list` (``cloudValue(_:)`` unwraps the relay's answer).
    ///   - history: This Mac's `cmux automation history --json` output.
    ///   - cloudHistory: Every Cloud run (`cmux automation history --target cloud --json`).
    ///   - cli: Runs `cmux --json WORDS…` (the page's buttons and form); nil: no buttons.
    public init(local: @escaping @Sendable () async throws -> Data, cloud: @escaping @Sendable () async throws -> Data,
                history: (@Sendable () async throws -> Data)? = nil,
                cloudHistory: (@Sendable () async throws -> Data)? = nil,
                cli: (@Sendable ([String]) async throws -> Data)? = nil) {
        model = AutomationsPage(local: local, cloud: cloud, history: history, cloudHistory: cloudHistory, cli: cli)
    }

    /// The host over this Mac's bundled `cmux`: its store (`automation list`, `history`) and every
    /// button and the form through the same CLI; Cloud through `cloud`.
    public convenience init(bundled: BundledExecutable, cloud: @escaping @Sendable () async throws -> Data) {
        let cli = Self.cli(bundled)
        self.init(local: { try await cli(["automation", "list"]) }, cloud: cloud,
                  history: { try await cli(["automation", "history", "--limit", "500"]) },
                  cloudHistory: { try await cli(["automation", "history", "--target", "cloud"]) }, cli: cli)
    }

    /// Runs `cmux --json WORDS…` with the bundled CLI; a failure throws its words as ``SourceError``.
    public nonisolated static func cli(_ bundled: BundledExecutable) -> @Sendable ([String]) async throws -> Data {
        { words in
            guard let cli = await bundled.resolve() else { throw SourceError(code: "no_cli", message: "") }
            let ran = try await ProcessRunner.run(executable: cli, arguments: ["--json"] + words, environment: nil,
                                                  timeout: .seconds(30), clock: ContinuousClock())
            guard ran.status == 0 else { throw SourceError(code: "cli_failed", message: cliMessage(stdout: ran.stdout, stderr: ran.stderr)) }
            return ran.stdout
        }
    }

    /// A new view of the page; it loads both sources when it appears and draws in `tokens()`, read
    /// again on each theme change (``AutomationsHostingView``).
    ///
    /// - Parameter tokens: The hosting window's current theme tokens (its `ThemeScope`).
    /// `automations.show` with a `name`: selects that automation and opens its newest log.
    public func show(named name: String?) {
        guard let name, !name.isEmpty else { return }
        Task { [model] in await model.show(named: name) }
    }

    public func makeView(tokens: @escaping @MainActor () -> ThemeTokens) -> NSView {
        AutomationsHostingView(model: model, tokens: tokens, actions: AutomationsPageView.Actions(signIn: signIn, openChat: openChat))
    }

    /// The words of a failed `cmux --json` command: its JSON error's message, else its stderr.
    public nonisolated static func cliMessage(stdout: Data, stderr: Data) -> String {
        for data in [stdout, stderr] {
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let error = object["error"] as? [String: Any] ?? object
                if let message = error["message"] as? String, !message.isEmpty { return message }
            }
        }
        let text = String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("cmux: ") ? String(text.dropFirst(6)) : text
    }

    /// The `value` of a `cloud.automation` answer as JSON bytes.
    ///
    /// - Throws: ``SourceError`` for a refusal (`{ok: false, error}`) or an answer that is not JSON.
    public nonisolated static func cloudValue(_ answer: Data) throws -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else {
            throw SourceError(code: "bad_reply", message: "")
        }
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any]
            throw SourceError(code: error?["code"] as? String ?? "error", message: error?["message"] as? String ?? "")
        }
        return try JSONSerialization.data(withJSONObject: object["value"] ?? [String: Any]())
    }
}
