import Foundation

struct DockBrowserProfileIndex {
    struct Resolution: Equatable, Sendable {
        let id: UUID
        let displayName: String
        let isDefault: Bool
    }

    private let defaultProfileID: UUID
    private let defaultProfileDisplayName: String
    private var displayNamesByID: [UUID: String] = [:]
    private var idsByReferenceKey: [String: [UUID]] = [:]

    init(defaultProfileID: UUID, defaultProfileDisplayName: String) {
        self.defaultProfileID = defaultProfileID
        self.defaultProfileDisplayName = defaultProfileDisplayName
    }

    mutating func addProfile(id: UUID, displayName: String, slug: String) {
        displayNamesByID[id] = displayName
        addReference(displayName, id: id)
        addReference(slug, id: id)
    }

    func resolve(_ reference: String?) throws -> Resolution {
        guard let reference else {
            return Resolution(
                id: defaultProfileID,
                displayName: defaultProfileDisplayName,
                isDefault: true
            )
        }

        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReference.isEmpty else {
            return Resolution(
                id: defaultProfileID,
                displayName: defaultProfileDisplayName,
                isDefault: true
            )
        }

        if let uuid = UUID(uuidString: normalizedReference) {
            guard let displayName = displayNamesByID[uuid] else {
                throw Self.unknownProfileError(normalizedReference)
            }
            return Resolution(
                id: uuid,
                displayName: displayName,
                isDefault: uuid == defaultProfileID
            )
        }

        let ids = idsByReferenceKey[Self.lookupKey(normalizedReference)] ?? []
        guard ids.count != 1 else {
            let id = ids[0]
            return Resolution(
                id: id,
                displayName: displayNamesByID[id] ?? normalizedReference,
                isDefault: id == defaultProfileID
            )
        }
        if ids.count > 1 {
            throw Self.ambiguousProfileError(normalizedReference)
        }
        throw Self.unknownProfileError(normalizedReference)
    }

    private mutating func addReference(_ reference: String, id: UUID) {
        let key = Self.lookupKey(reference)
        guard !key.isEmpty else { return }
        var ids = idsByReferenceKey[key] ?? []
        if !ids.contains(id) {
            ids.append(id)
        }
        idsByReferenceKey[key] = ids
    }

    private static func lookupKey(_ reference: String) -> String {
        reference
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func unknownProfileError(_ reference: String) -> NSError {
        NSError(
            domain: "cmux.dock",
            code: 6,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: String(
                        localized: "dock.error.unknownBrowserProfile",
                        defaultValue: "Dock browser profile '%@' does not match a cmux browser profile."
                    ),
                    reference
                )
            ]
        )
    }

    private static func ambiguousProfileError(_ reference: String) -> NSError {
        NSError(
            domain: "cmux.dock",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: String(
                        localized: "dock.error.ambiguousBrowserProfile",
                        defaultValue: "Dock browser profile '%@' matches multiple cmux browser profiles. Use the profile ID instead."
                    ),
                    reference
                )
            ]
        )
    }
}
