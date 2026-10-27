public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The Stats page (webviews/src/pages/stats, hq#1920): this computer's agent work, read only.
    /// Its one op `cmux.stats.summary` is relayed to the local acpmux, which folds its session logs;
    /// nothing leaves the machine.
    static let stats = PageDescriptor(id: "cmux.stats", resource: "stats", processGroup: .privileged, namespaces: ["cmux.stats."],
                                      opTables: [PageOpTable(namespace: "cmux.stats.", read: ["summary"])])
}

/// `cmux.stats.summary {days, tzOffsetMinutes}`: one `_acpmux/stats` request to this app's acpmux,
/// whose answer (counts and times only) goes back to the page as is. `send` delivers one request
/// line and returns the reply line, or nil when there is no acpmux to ask; it throws on a closed
/// connection or its deadline. `allowed` is asked on every call, so a tab restored or left open
/// after `labs.previewFeatures` turned off scans nothing.
@MainActor
public final class StatsPageProvider: PageProvider {
    private let allowed: @MainActor () -> Bool
    private let send: @Sendable (Data) async throws -> Data?

    public init(allowed: @escaping @MainActor () -> Bool, send: @escaping @Sendable (Data) async throws -> Data?) {
        self.allowed = allowed
        self.send = send
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == "cmux.stats.summary" else { throw PageError.unknownOp(op) }
        guard allowed() else { throw PageError(code: "cmux.stats.unavailable", message: Self.previewRefusal, retryable: true) }
        // Only the two numbers reach acpmux, which clamps them.
        var request: [String: JSONValue] = [:]
        if let days = params["days"]?.doubleValue { request["days"] = .number(days) }
        if let offset = params["tzOffsetMinutes"]?.doubleValue { request["tzOffsetMinutes"] = .number(offset) }
        let line: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "_acpmux/stats", "params": .object(request)]
        let reply: Data?
        do {
            reply = try await send(Data((line.compactText + "\n").utf8))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PageError(code: "cmux.stats.unavailable", message: Self.unavailable, retryable: true)
        }
        guard let reply, let message = try? JSONValue.parse(reply) else {
            throw PageError(code: "cmux.stats.unavailable", message: Self.unavailable, retryable: true)
        }
        if let failure = message["error"]?["message"]?.stringValue {
            throw PageError(code: "cmux.stats.failed", message: failure, retryable: true)
        }
        return message["result"] ?? .null
    }

    /// The tab's title.
    public static var title: String { t("stats.tab.title", "Agent Stats") }
    /// Why `stats.show` is unavailable while `labs.previewFeatures` is off.
    public static var previewRefusal: String {
        t("stats.refusal.preview", "Agent Stats is a preview feature: turn on Show Preview Features in Settings.")
    }

    static var unavailable: String {
        t("stats.unavailable", "The agent service is not running or did not answer, so there is nothing to count yet.")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
