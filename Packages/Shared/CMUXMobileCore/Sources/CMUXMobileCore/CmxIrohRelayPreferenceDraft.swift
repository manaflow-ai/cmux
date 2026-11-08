/// A user-visible relay preference shared by the macOS and iOS settings surfaces.
public enum CmxIrohRelayPreferenceDraft: Equatable, Sendable {
    /// Allow every relay in the signed cmux catalog and let Iroh choose.
    case automatic

    /// Allow only the selected stable relay identifiers from the signed catalog.
    case managed(Set<String>)

    /// Disable managed relays and use the account's custom relay definitions.
    case custom

    /// Returns this preference after enforcing the cross-platform UI boundary.
    /// Controllers must call this before persistence so an alternate settings
    /// entrypoint cannot create an empty or oversized managed selection.
    public func validated() throws -> Self {
        guard case let .managed(ids) = self else { return self }
        guard (1 ... 16).contains(ids.count), ids.allSatisfy(Self.isSafeRelayID) else {
            throw CmxIrohRelayPreferenceDraftError.invalidManagedSelection
        }
        return self
    }

    private static func isSafeRelayID(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }
}
