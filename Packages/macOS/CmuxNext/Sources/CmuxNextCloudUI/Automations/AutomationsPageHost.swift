public import AppKit
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

    /// Makes the host.
    ///
    /// - Parameters:
    ///   - local: This Mac's `cmux automation list --json` output.
    ///   - cloud: The `value` of a Cloud `automation.list` (``cloudValue(_:)`` unwraps the relay's answer).
    public init(local: @escaping @Sendable () async throws -> Data, cloud: @escaping @Sendable () async throws -> Data) {
        model = AutomationsPage(local: local, cloud: cloud)
    }

    /// A new view of the page; it loads both sources when it appears and draws in `tokens()`, read
    /// again on each theme change (``AutomationsHostingView``).
    ///
    /// - Parameter tokens: The hosting window's current theme tokens (its `ThemeScope`).
    public func makeView(tokens: @escaping @MainActor () -> ThemeTokens) -> NSView {
        AutomationsHostingView(model: model, tokens: tokens)
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
