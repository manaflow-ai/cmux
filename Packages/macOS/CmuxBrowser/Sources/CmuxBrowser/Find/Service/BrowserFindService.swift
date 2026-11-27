import Foundation
internal import os

/// Runs find-in-page searches against a page and reports validated match counts.
///
/// `BrowserFindService` is the side-effecting capability behind a browser panel's find bar: it
/// generates the find scripts, evaluates them through an injected ``BrowserFindScriptEvaluating``
/// seam, and parses each result into a ``BrowserFindMatchCount``. It owns no UI state and never
/// touches the web view, the window, or panel focus; the panel owns the find bar state and decides
/// what to do with the returned counts. It is `@MainActor` because WebKit's `evaluateJavaScript`
/// is main-thread only.
@MainActor
public final class BrowserFindService {
    private let evaluator: any BrowserFindScriptEvaluating
    private let log = Logger(subsystem: "com.cmux.browser", category: "find")

    /// Creates a find service bound to a script evaluator.
    /// - Parameter evaluator: The seam that evaluates find scripts in the page.
    public init(evaluator: any BrowserFindScriptEvaluating) {
        self.evaluator = evaluator
    }

    /// Runs a search for `needle` and returns the resulting match count.
    ///
    /// A non-empty needle highlights matches in the page. If WebKit raises an error the failure is
    /// logged and `nil` is returned so the caller leaves the existing count untouched. An empty
    /// needle is not searched: the caller should clear highlights via ``clear()`` and reset its
    /// own count, mirroring the original empty-needle short-circuit.
    /// - Parameter needle: The text to search for.
    /// - Returns: The parsed match count, or `nil` when the search errored or the needle was empty.
    public func search(needle: String) async -> BrowserFindMatchCount? {
        guard !needle.isEmpty else { return nil }
        do {
            let result = try await evaluator.evaluate(.search(query: needle))
            return BrowserFindMatchCount.parse(result)
        } catch {
            log.error("browser JS search error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Advances to the next match and returns the resulting match count.
    ///
    /// Errors are swallowed and reported as `nil`, matching the original `try?` behavior.
    /// - Returns: The parsed match count, or `nil` when the script errored or produced no result.
    public func next() async -> BrowserFindMatchCount? {
        let result = try? await evaluator.evaluate(.next())
        return BrowserFindMatchCount.parse(result)
    }

    /// Moves to the previous match and returns the resulting match count.
    ///
    /// Errors are swallowed and reported as `nil`, matching the original `try?` behavior.
    /// - Returns: The parsed match count, or `nil` when the script errored or produced no result.
    public func previous() async -> BrowserFindMatchCount? {
        let result = try? await evaluator.evaluate(.previous())
        return BrowserFindMatchCount.parse(result)
    }

    /// Removes all find highlights from the page.
    ///
    /// Errors are logged and otherwise ignored, matching the original clear behavior. The clear
    /// script does not report a count, so no value is returned.
    public func clear() async {
        do {
            _ = try await evaluator.evaluate(.clear())
        } catch {
            log.error("browser JS clear error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
