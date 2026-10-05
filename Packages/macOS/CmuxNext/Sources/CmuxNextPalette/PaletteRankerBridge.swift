public import Foundation
import JavaScriptCore

/// Errors raised while loading or invoking the shared TypeScript palette ranker.
public enum PaletteRankerBridgeError: Error, LocalizedError, Sendable {
    /// The checked-in bridge bundle was not included in the palette resource bundle.
    case resourceMissing
    /// JavaScriptCore could not allocate a context for the bridge.
    case runtimeUnavailable
    /// The shared ranker threw while loading or processing a request.
    case runtimeFailed(String)
    /// The bridge returned a value that is not a ranked-section payload.
    case invalidResult

    public var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "the shared palette ranker resource is missing"
        case .runtimeUnavailable:
            "JavaScriptCore could not create a palette ranker context"
        case .runtimeFailed(let message):
            "the shared palette ranker failed: \(message)"
        case .invalidResult:
            "the shared palette ranker returned an invalid result"
        }
    }
}

/// Thin native bridge to the shared TypeScript ranker.
///
/// A bridge owns one JavaScriptCore context and is safe to use from the actor
/// that owns it. The palette keeps ranking inputs and rendering in Swift, while
/// the scoring, frecency and tie-breaking rules live in `webviews/src/palette`.
public final class PaletteRankerBridge {
    // crash-allow: JavaScriptCore is serialized by each owning actor or Mutex-protected ranker.
    nonisolated(unsafe) private let context: JSContext

    /// Creates a bridge from the checked-in JavaScriptCore-compatible bundle.
    nonisolated public init() throws {
        guard let context = JSContext() else { throw PaletteRankerBridgeError.runtimeUnavailable }
        guard let url = Bundle.module.url(forResource: "palette-ranker", withExtension: "js") else {
            throw PaletteRankerBridgeError.resourceMissing
        }
        let source: String
        do {
            // concurrency-allow: the small checked-in bundle is read once while constructing a persistent bridge.
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PaletteRankerBridgeError.runtimeFailed("cannot read \(url.lastPathComponent): \(error)")
        }
        self.context = context
        context.evaluateScript(source, withSourceURL: url)
        if let exception = context.exception?.toString() {
            throw PaletteRankerBridgeError.runtimeFailed(exception)
        }
        guard let function = context.objectForKeyedSubscript("__cmuxPaletteRank"), !function.isUndefined else {
            throw PaletteRankerBridgeError.runtimeFailed("bridge entry point is missing")
        }
    }

    /// Ranks a palette index through the shared TypeScript implementation.
    nonisolated public func rank(
        index: PaletteSearchIndex,
        version: Int? = nil,
        query: String,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        keepsSectionOrder: Bool = false,
        ranksPrefixFirst: Bool = false,
        recentLimit: Int = 5,
        rowLimit: Int = 400,
        highlightLimit: Int = 60
    ) throws -> [PaletteRankedSection] {
        try invoke(PaletteRankerBridgeRequest(
            operation: "rank",
            entries: index.entries.map(PaletteRankerBridgeEntry.init),
            version: version,
            query: query,
            sectionOrders: sectionOrders,
            frecency: PaletteRankerBridgeFrecency(frecency),
            now: now.timeIntervalSinceReferenceDate,
            showsRecent: showsRecent,
            keepsSectionOrder: keepsSectionOrder,
            ranksPrefixFirst: ranksPrefixFirst,
            recentLimit: recentLimit,
            rowLimit: rowLimit,
            highlightLimit: highlightLimit
        ))
    }

    /// Ranks an empty palette query through the shared TypeScript implementation.
    nonisolated public func rankEmpty(
        entries: [PaletteSearchEntry],
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int = 5
    ) throws -> [PaletteRankedSection] {
        try invoke(PaletteRankerBridgeRequest(
            operation: "rankEmpty",
            entries: entries.map(PaletteRankerBridgeEntry.init),
            version: nil,
            query: nil,
            sectionOrders: sectionOrders,
            frecency: PaletteRankerBridgeFrecency(frecency),
            now: now.timeIntervalSinceReferenceDate,
            showsRecent: showsRecent,
            keepsSectionOrder: false,
            ranksPrefixFirst: false,
            recentLimit: recentLimit,
            rowLimit: 400,
            highlightLimit: 60
        ))
    }

    nonisolated private func invoke(_ request: PaletteRankerBridgeRequest) throws -> [PaletteRankedSection] {
        let data = try JSONEncoder().encode(request)
        guard let requestJSON = String(data: data, encoding: .utf8),
              let function = context.objectForKeyedSubscript("__cmuxPaletteRank") else {
            throw PaletteRankerBridgeError.invalidResult
        }
        context.exception = nil
        let value = function.call(withArguments: [requestJSON])
        if let exception = context.exception?.toString() {
            throw PaletteRankerBridgeError.runtimeFailed(exception)
        }
        guard let resultJSON = value?.toString(), let resultData = resultJSON.data(using: .utf8) else {
            throw PaletteRankerBridgeError.invalidResult
        }
        do {
            let sections = try JSONDecoder().decode([PaletteRankerBridgeSection].self, from: resultData)
            return sections.map { section in
                PaletteRankedSection(
                    sectionIndex: section.sectionIndex,
                    rows: section.rows.map { row in
                        PaletteRankedRow(index: row.index, score: row.score, highlights: row.highlights)
                    }
                )
            }
        } catch {
            throw PaletteRankerBridgeError.runtimeFailed("invalid result JSON: \(error)")
        }
    }
}
