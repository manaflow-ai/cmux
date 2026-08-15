/// Parsed subset of `Page.getNavigationHistory` used for native back/forward.
struct ChromiumNavigationHistory: Equatable, Sendable {
    let currentIndex: Int
    let entryIDs: [Int]

    init(_ value: CDPValue) throws {
        guard case .object(let object) = value,
              let rawIndex = object["currentIndex"]?.doubleValue,
              let currentIndex = Int(exactly: rawIndex),
              case .array(let entries)? = object["entries"] else {
            throw Self.malformedError
        }

        let entryIDs = try entries.map { entry -> Int in
            guard case .object(let entryObject) = entry,
                  let rawID = entryObject["id"]?.doubleValue,
                  let entryID = Int(exactly: rawID) else {
                throw Self.malformedError
            }
            return entryID
        }
        guard entryIDs.indices.contains(currentIndex) else {
            throw Self.malformedError
        }
        self.currentIndex = currentIndex
        self.entryIDs = entryIDs
    }

    var canGoBack: Bool { currentIndex > entryIDs.startIndex }
    var canGoForward: Bool { currentIndex < entryIDs.index(before: entryIDs.endIndex) }

    func targetEntryID(offset: Int) -> Int? {
        let targetIndex = currentIndex + offset
        guard entryIDs.indices.contains(targetIndex) else { return nil }
        return entryIDs[targetIndex]
    }

    private static var malformedError: CDPError {
        .protocolError(ChromiumBrowserDiagnostic.malformedNavigationHistory.message)
    }
}
