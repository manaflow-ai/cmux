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

private struct PaletteRankerEntry: Encodable {
    let title: String
    let keywords: [String]
    let subtitle: String?
    let accessory: String?
    let rankBias: Int
    let frecencyKey: String?
    let isEnabled: Bool
    let isVisibleWhenQueryEmpty: Bool
    let queryPrefix: String?
    let hidesWhenTyping: Bool
    let sectionIndex: Int

    init(_ entry: PaletteSearchEntry) {
        title = entry.title
        keywords = entry.keywords
        subtitle = entry.subtitle
        accessory = entry.accessory
        rankBias = entry.rankBias
        frecencyKey = entry.frecencyKey
        isEnabled = entry.isEnabled
        isVisibleWhenQueryEmpty = entry.isVisibleWhenQueryEmpty
        queryPrefix = entry.queryPrefix
        hidesWhenTyping = entry.hidesWhenTyping
        sectionIndex = entry.sectionIndex
    }
}

private struct PaletteRankerFrecencyEntry: Encodable {
    let score: Double
    let lastUsed: Double
}

private struct PaletteRankerFrecency: Encodable {
    let entries: [String: PaletteRankerFrecencyEntry]
    let halfLife: Double
    let capacity: Int

    init(_ store: FrecencyStore) {
        entries = store.entries.mapValues { entry in
            PaletteRankerFrecencyEntry(score: entry.score, lastUsed: entry.lastUsed.timeIntervalSinceReferenceDate)
        }
        halfLife = store.halfLife
        capacity = store.capacity
    }
}

private struct PaletteRankerRequest: Encodable {
    let operation: String
    let entries: [PaletteRankerEntry]
    let version: Int?
    let query: String?
    let sectionOrders: [Int]
    let frecency: PaletteRankerFrecency
    let now: Double
    let showsRecent: Bool
    let keepsSectionOrder: Bool
    let ranksPrefixFirst: Bool
    let recentLimit: Int
    let rowLimit: Int
    let highlightLimit: Int
}

private struct PaletteRankerRow: Decodable {
    let index: Int
    let score: Int
    let highlights: [Int]
}

private struct PaletteRankerSection: Decodable {
    let sectionIndex: Int?
    let rows: [PaletteRankerRow]
}

/// Thin native bridge to the shared TypeScript ranker.
///
/// A bridge owns one JavaScriptCore context and is safe to use from the actor
/// that owns it. The palette keeps ranking inputs and rendering in Swift, while
/// the scoring, frecency and tie-breaking rules live in `webviews/src/palette`.
public final class PaletteRankerBridge {
    private let context: JSContext

    /// Creates a bridge from the checked-in JavaScriptCore-compatible bundle.
    public init() throws {
        guard let context = JSContext() else { throw PaletteRankerBridgeError.runtimeUnavailable }
        guard let url = Bundle.module.url(forResource: "palette-ranker", withExtension: "js") else {
            throw PaletteRankerBridgeError.resourceMissing
        }
        let source: String
        do {
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
    public func rank(
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
        try invoke(PaletteRankerRequest(
            operation: "rank",
            entries: index.entries.map(PaletteRankerEntry.init),
            version: version,
            query: query,
            sectionOrders: sectionOrders,
            frecency: PaletteRankerFrecency(frecency),
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
    public func rankEmpty(
        entries: [PaletteSearchEntry],
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int = 5
    ) throws -> [PaletteRankedSection] {
        try invoke(PaletteRankerRequest(
            operation: "rankEmpty",
            entries: entries.map(PaletteRankerEntry.init),
            version: nil,
            query: nil,
            sectionOrders: sectionOrders,
            frecency: PaletteRankerFrecency(frecency),
            now: now.timeIntervalSinceReferenceDate,
            showsRecent: showsRecent,
            keepsSectionOrder: false,
            ranksPrefixFirst: false,
            recentLimit: recentLimit,
            rowLimit: 400,
            highlightLimit: 60
        ))
    }

    private func invoke(_ request: PaletteRankerRequest) throws -> [PaletteRankedSection] {
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
            let sections = try JSONDecoder().decode([PaletteRankerSection].self, from: resultData)
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
