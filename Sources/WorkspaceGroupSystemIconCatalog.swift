import Foundation
import OSLog

nonisolated private let workspaceGroupSystemIconCatalogLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "WorkspaceGroupSystemIconCatalog"
)

struct WorkspaceGroupSystemIconCatalog: Sendable {
    struct Candidate: Identifiable, Equatable, Sendable {
        let name: String
        let searchTerms: [String]

        var id: String { name }

        func matches(query: String) -> Bool {
            name.localizedCaseInsensitiveContains(query) ||
                searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    static let fallback = WorkspaceGroupSystemIconCatalog(
        names: fallbackSymbolNames,
        searchTerms: fallbackSearchTerms()
    )

    private let candidates: [Candidate]

    private init(names: [String], searchTerms: [String: [String]]) {
        candidates = names.map { name in
            Candidate(name: name, searchTerms: searchTerms[name] ?? [])
        }
    }

    static func load() async -> WorkspaceGroupSystemIconCatalog {
        await Task.detached(priority: .utility) {
            let names = Self.loadSymbolNames()
            let searchTerms = Self.loadSearchTerms()
            return WorkspaceGroupSystemIconCatalog(names: names, searchTerms: searchTerms)
        }.value
    }

    @MainActor
    func matching(query rawQuery: String, limit: Int) -> [Candidate] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [Candidate] = []
        results.reserveCapacity(min(limit, 256))

        for candidate in candidates {
            guard query.isEmpty || candidate.matches(query: query) else { continue }
            guard RenderableSystemSymbol.isRenderable(candidate.name) else { continue }
            results.append(candidate)
            if results.count >= limit {
                break
            }
        }

        return results
    }

    private static let symbolOrderPath = "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphsPrivate.bundle/Contents/Resources/symbol_order.plist"
    private static let symbolSearchPath = "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphsPrivate.bundle/Contents/Resources/symbol_search.plist"

    private static func loadSymbolNames() -> [String] {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: symbolOrderPath))
            guard let names = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String],
                  !names.isEmpty else {
                workspaceGroupSystemIconCatalogLogger.warning("invalid SF Symbols order plist at \(symbolOrderPath, privacy: .public)")
                return fallbackSymbolNames
            }
            return names
        } catch {
            workspaceGroupSystemIconCatalogLogger.warning("failed to load SF Symbols order plist at \(symbolOrderPath, privacy: .public): \(String(describing: error), privacy: .public)")
            return fallbackSymbolNames
        }
    }

    private static func loadSearchTerms() -> [String: [String]] {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: symbolSearchPath))
            guard let terms = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: [String]] else {
                workspaceGroupSystemIconCatalogLogger.warning("invalid SF Symbols search plist at \(symbolSearchPath, privacy: .public)")
                return fallbackSearchTerms()
            }
            return terms
        } catch {
            workspaceGroupSystemIconCatalogLogger.warning("failed to load SF Symbols search plist at \(symbolSearchPath, privacy: .public): \(String(describing: error), privacy: .public)")
            return fallbackSearchTerms()
        }
    }

    private static let fallbackSymbolNames = [
        "folder.fill", "folder", "leaf.fill", "sparkles", "terminal.fill", "chevron.right",
        "wrench.and.screwdriver.fill", "gearshape.fill", "hammer.fill", "ladybug.fill",
        "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill",
        "doc.text.fill", "globe", "lock.fill", "key.fill", "bolt.fill", "flame.fill",
        "star.fill", "heart.fill", "bookmark.fill", "tray.full.fill", "shippingbox.fill"
    ]

    private static func fallbackSearchTerms() -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: fallbackSymbolNames.map { name in
            (name, symbolNameSearchTerms(name))
        })
    }

    private static func symbolNameSearchTerms(_ name: String) -> [String] {
        var terms = [name]
        for token in name.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }) {
            let value = String(token)
            guard !terms.contains(value) else { continue }
            terms.append(value)
        }
        return terms
    }
}
