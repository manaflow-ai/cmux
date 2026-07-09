import Foundation

struct DockBrowserProfileIndex {
    private let defaultProfileID: UUID
    private let defaultProfileDisplayName: String
    private var displayNamesByID: [UUID: String] = [:]

    init(defaultProfileID: UUID, defaultProfileDisplayName: String) {
        self.defaultProfileID = defaultProfileID
        self.defaultProfileDisplayName = defaultProfileDisplayName
    }

    mutating func addProfile(id: UUID, displayName: String) {
        displayNamesByID[id] = displayName
    }

    func resolve(_ reference: String?) throws -> DockBrowserProfileResolution {
        guard let reference else {
            return DockBrowserProfileResolution(
                id: defaultProfileID,
                displayName: defaultProfileDisplayName,
                isDefault: true
            )
        }

        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReference.isEmpty else {
            return DockBrowserProfileResolution(
                id: defaultProfileID,
                displayName: defaultProfileDisplayName,
                isDefault: true
            )
        }

        if let uuid = UUID(uuidString: normalizedReference) {
            if let displayName = displayNamesByID[uuid] {
                return DockBrowserProfileResolution(
                    id: uuid,
                    displayName: displayName,
                    isDefault: uuid == defaultProfileID
                )
            }
        }

        throw Self.unknownProfileError(normalizedReference)
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

}
