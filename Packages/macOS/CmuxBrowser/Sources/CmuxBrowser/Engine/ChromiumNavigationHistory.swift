import Foundation

/// Parsed subset of `Page.getNavigationHistory` used for native back/forward.
struct ChromiumNavigationHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let id: Int
        let url: URL?
    }

    let currentIndex: Int
    let entries: [Entry]

    init(_ value: CDPValue) throws {
        guard case .object(let object) = value,
              let rawIndex = object["currentIndex"]?.doubleValue,
              let currentIndex = Int(exactly: rawIndex),
              case .array(let entries)? = object["entries"] else {
            throw Self.malformedError
        }

        let parsedEntries = try entries.map { entry -> Entry in
            guard case .object(let entryObject) = entry,
                  let rawID = entryObject["id"]?.doubleValue,
                  let entryID = Int(exactly: rawID) else {
                throw Self.malformedError
            }
            let rawURL = entryObject["url"]?.stringValue
                ?? entryObject["userTypedURL"]?.stringValue
            return Entry(id: entryID, url: rawURL.flatMap(URL.init(string:)))
        }
        guard parsedEntries.indices.contains(currentIndex) else {
            throw Self.malformedError
        }
        self.currentIndex = currentIndex
        self.entries = parsedEntries
    }

    var entryIDs: [Int] { entries.map(\.id) }

    var canGoBack: Bool { currentIndex > entries.startIndex }
    var canGoForward: Bool { currentIndex < entries.index(before: entries.endIndex) }

    /// Back entries ordered oldest-first for session persistence.
    var backURLs: [URL] {
        entries[..<currentIndex].compactMap(\.url)
    }

    /// Forward entries ordered nearest-first for session persistence.
    var forwardURLs: [URL] {
        guard currentIndex + 1 < entries.endIndex else { return [] }
        return entries[(currentIndex + 1)...].compactMap(\.url)
    }

    func targetEntryID(offset: Int) -> Int? {
        let targetIndex = currentIndex + offset
        guard entries.indices.contains(targetIndex) else { return nil }
        return entries[targetIndex].id
    }

    private static var malformedError: CDPError {
        .protocolError(ChromiumBrowserDiagnostic.malformedNavigationHistory.message)
    }
}
