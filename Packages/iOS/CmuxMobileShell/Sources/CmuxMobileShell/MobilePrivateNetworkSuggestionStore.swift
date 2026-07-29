public import CMUXMobileCore
public import Foundation

/// Process-memory storage for authenticated private-address suggestions.
///
/// The store has no persistence dependency. Suggestions disappear when the
/// process exits or ``removeAll()`` is called at an account boundary.
@MainActor
public final class MobilePrivateNetworkSuggestionStore {
    private var addressesByMacDeviceID: [String: [CmxPrivateNetworkAddress]] = [:]
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    /// Creates an empty device-local suggestion store.
    public init() {}

    /// Replaces one Mac's suggestions using its canonical device identifier.
    ///
    /// Empty suggestion arrays remove the entry. Duplicate addresses are
    /// normalized through ``CmxPrivateNetworkAddress/sorted(_:)``.
    ///
    /// - Parameters:
    ///   - addresses: Authenticated status suggestions for the Mac.
    ///   - macDeviceID: The Mac device identifier from the same status payload.
    public func record(
        _ addresses: [CmxPrivateNetworkAddress],
        forMacDeviceID macDeviceID: String
    ) {
        let trimmedID = macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        let canonicalID = cmxCanonicalDeviceID(trimmedID)
        let sortedAddresses = CmxPrivateNetworkAddress.sorted(addresses)
        guard addressesByMacDeviceID[canonicalID] != sortedAddresses else {
            return
        }
        if sortedAddresses.isEmpty {
            addressesByMacDeviceID.removeValue(forKey: canonicalID)
        } else {
            addressesByMacDeviceID[canonicalID] = sortedAddresses
        }
        for continuation in continuations.values {
            continuation.yield(canonicalID)
        }
    }

    /// Returns one Mac's current in-memory suggestions.
    ///
    /// - Parameter macDeviceID: The Mac device identifier to canonicalize.
    /// - Returns: The latest stable suggestion list, or an empty list.
    public func suggestions(
        forMacDeviceID macDeviceID: String
    ) -> [CmxPrivateNetworkAddress] {
        addressesByMacDeviceID[cmxCanonicalDeviceID(macDeviceID)] ?? []
    }

    /// Removes all suggestions at an account boundary.
    public func removeAll() {
        guard !addressesByMacDeviceID.isEmpty else { return }
        addressesByMacDeviceID = [:]
        for continuation in continuations.values {
            continuation.yield("")
        }
    }

    /// Observes Mac identifiers whose in-memory suggestion snapshot changed.
    ///
    /// - Returns: A newest-only stream that finishes when its consumer ends.
    public func updates() -> AsyncStream<String> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }
}
