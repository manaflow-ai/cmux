public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The page's JSON (CmuxNextSettings), not the daemon's.
private typealias PageJSON = CmuxNextSettings.JSONValue

/// The host side of an extension's web pane (`render: web`): the one door from the page to cmux.
///
/// The page calls `<host>.<op>` on the shared page bridge (`cmux-extension-sdk/web` does it
/// for the author), where `<host>` is its origin (`local.web-pane`), so the page's descriptor
/// admits only its own namespace. This provider strips the prefix and sends the page's
/// `{id, op, params}` to the daemon as `apps-page-call`, unparsed, where the app's grant decides
/// it exactly as for the app's QuickJS script (scope table, consent, async only, 256 KiB a
/// message, 200 calls a second). Nothing here widens or decides access; a refusal comes back as
/// the page call's error (`scope.missing`, `rate.limited`, ...).
@MainActor
public final class AppWebPaneProvider: PageProvider {
    public let appID: String
    /// This open page's key on the daemon (its own call budget).
    public let pageKey: String
    /// `<host>.`: the namespace the page's ops carry.
    public let prefix: String
    private let call: @MainActor (_ message: String) async throws(AppsTransportError) -> AppJSON
    private var nextID: UInt64 = 0

    /// `call` sends one raw message for this page (``AppsClient/pageCall(app:page:message:)``).
    public init(appID: String, pageKey: String, prefix: String,
                call: @escaping @MainActor (_ message: String) async throws(AppsTransportError) -> AppJSON) {
        self.appID = appID
        self.pageKey = pageKey
        self.prefix = prefix
        self.call = call
    }

    public func call(_ op: String, params: PageJSON, context: PageCallContext) async throws -> PageJSON {
        guard op.hasPrefix(prefix), op.count > prefix.count else { throw PageError.unknownOp(op) }
        nextID += 1
        let message: PageJSON = ["id": .string(String(nextID)), "op": .string(String(op.dropFirst(prefix.count))), "params": params]
        let answer: AppJSON
        do {
            answer = try await call(message.compactText)
        } catch {
            throw PageError(code: error.code ?? "operation.failed", message: error.message, retryable: error.connectionLost)
        }
        if answer["ok"]?.boolValue == true { return Self.pageJSON(answer["value"] ?? .null) }
        let failure = answer["error"]
        throw PageError(code: failure?["code"]?.stringValue ?? "operation.failed",
                        message: failure?["message"]?.stringValue ?? "",
                        retryable: failure?["retryable"]?.boolValue ?? false,
                        details: failure?["details"].map(Self.pageJSON))
    }

    /// The daemon's answer as the page's JSON: the same value, converted at this edge.
    nonisolated static func pageJSON(_ value: AppJSON) -> PageJSON {
        switch value {
        case .null: .null
        case .bool(let v): .bool(v)
        case .number(let v): .number(v)
        case .string(let v): .string(v)
        case .array(let v): .array(v.map(pageJSON))
        case .object(let v): .object(v.mapValues(pageJSON))
        }
    }
}

public extension AppsClient {
    /// One raw bridge message of `app`'s web pane `page` (`apps-page-call`); the daemon answers
    /// `{id, ok, value | error}`.
    func pageCall(app: String, page: String, message: String) async throws(AppsTransportError) -> AppJSON {
        if case .unavailable(let reason) = availability {
            throw AppsTransportError(message: AppsStrings.unavailable(reason), connectionLost: true)
        }
        return try await transport.pageCall(app: app, page: page, message: message)
    }
}
