public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The Chief Usage page (webviews/src/pages/chief-usage,
    /// plans/cmux-next/chief-usage-analytics-DESIGN.md): tokens, cost, cache hit and turn time of
    /// this Mac's Chiefs over time, read only. Its one op `cmux.chief_usage.summary` runs the
    /// bundled `optchat-chief usage --json`; nothing leaves the machine.
    static let chiefUsage = PageDescriptor(id: "cmux.chief-usage", resource: "chief-usage", namespaces: ["cmux.chief_usage."])
}

/// `cmux.chief_usage.summary {since, by, top, bucket?}`: one `optchat-chief usage` run, whose
/// JSON summary goes back to the page as is.
///
/// Every param is checked against an allowlist before anything runs, so a page can never pass a
/// flag or a path to the tool. `run` gets the arguments after the tool's name (`usage --since 7d
/// --by chief --top 8`); the app's runner adds the Chief home and `--json`. It returns the tool's
/// standard output, nil when this build has no tool, and throws on a non-zero exit.
///
/// ```swift
/// let provider = ChiefUsagePageProvider { arguments in
///     try await tool?.run(arguments, muxHome: home)
/// }
/// ```
@MainActor
public final class ChiefUsagePageProvider: PageProvider {
    /// The `--since` windows the tool takes.
    public static let windows: Set<String> = ["24h", "7d", "30d", "90d", "1y", "all"]
    /// The `--by` groupings the tool takes.
    public static let groupings: Set<String> = ["chief", "agent", "model", "harness", "kind"]
    /// The `--bucket` sizes the tool takes.
    public static let buckets: Set<String> = ["hour", "day", "week", "month"]
    /// The `--top` range.
    public static let topRange: ClosedRange<Int> = 0...50

    private let run: @Sendable ([String]) async throws -> Data?

    /// - Parameter run: Runs `optchat-chief` with these arguments and returns its standard
    ///   output; nil when this build has no tool. Throws on a non-zero exit.
    public init(run: @escaping @Sendable ([String]) async throws -> Data?) {
        self.run = run
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == "cmux.chief_usage.summary" else { throw PageError.unknownOp(op) }
        let arguments = try Self.arguments(params)
        let output: Data?
        do {
            output = try await run(arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PageError(code: "cmux.chief_usage.failed", message: Self.failed, retryable: true,
                            details: ["reason": .string(String(describing: error))])
        }
        guard let output else {
            throw PageError(code: "cmux.chief_usage.unavailable", message: Self.unavailable)
        }
        guard let summary = try? JSONValue.parse(output) else {
            throw PageError(code: "cmux.chief_usage.failed", message: Self.failed, retryable: true)
        }
        return summary
    }

    /// The `optchat-chief` arguments for `params` (`usage` then each given flag), or
    /// ``PageError/invalidParams(_:)`` for a value outside its allowlist. A missing or null
    /// param leaves its flag out, so the tool's default applies.
    static func arguments(_ params: JSONValue) throws -> [String] {
        var arguments = ["usage"]
        func choice(_ key: String, flag: String, in allowed: Set<String>) throws {
            guard let value = params[key], !value.isNull else { return }
            guard let text = value.stringValue, allowed.contains(text) else {
                throw PageError.invalidParams("\(key) must be one of \(allowed.sorted().joined(separator: ", "))")
            }
            arguments += [flag, text]
        }
        try choice("since", flag: "--since", in: windows)
        try choice("by", flag: "--by", in: groupings)
        if let value = params["top"], !value.isNull {
            guard let top = value.intValue, topRange.contains(top) else {
                throw PageError.invalidParams("top must be an integer from \(topRange.lowerBound) to \(topRange.upperBound)")
            }
            arguments += ["--top", String(top)]
        }
        try choice("bucket", flag: "--bucket", in: buckets)
        return arguments
    }

    /// The tab's title.
    public static var title: String { t("chiefUsage.tab.title", "Chief Usage") }
    /// The Chief menu's item that opens the page.
    public static var menuTitle: String { t("chiefUsage.menu.usage", "Usage…") }
    /// Why `chief.openUsage` is unavailable: this build has no local Chief.
    public static var noLocalChief: String {
        t("chiefUsage.refusal.noLocalChief", "Chief Usage reads the Chief that runs on this Mac, and this build has no local Chief.")
    }

    static var unavailable: String {
        t("chiefUsage.unavailable", "This build does not include the Chief's usage tool, so there is no usage to show.")
    }

    static var failed: String {
        t("chiefUsage.failed", "The Chief's usage could not be read. Try again.")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
