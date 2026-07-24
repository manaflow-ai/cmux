public import CMUXMobileCore
public import Foundation

/// Pure text transformations for adding discovered addresses to the editor.
public struct MobilePrivateNetworkSuggestionText: Sendable {
    /// Creates a stateless private-network suggestion text helper.
    public init() {}

    /// Appends a canonical suggestion unless the text already contains it.
    ///
    /// Existing lines are parsed through ``CmxIrohCustomPrivateAddress`` so
    /// alternate numeric spellings, including expanded IPv6, deduplicate.
    ///
    /// - Parameters:
    ///   - suggestion: The discovered address to append.
    ///   - addressesText: The editor's newline-delimited address text.
    /// - Returns: The original text when present, otherwise text with the
    ///   canonical suggestion appended on its own line.
    public func appending(
        _ suggestion: CmxPrivateNetworkAddress,
        to addressesText: String
    ) -> String {
        guard !contains(suggestion, in: addressesText) else {
            return addressesText
        }
        guard !addressesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return suggestion.address
        }
        let separator = addressesText.hasSuffix("\n") ? "" : "\n"
        return addressesText + separator + suggestion.address
    }

    /// Reports whether newline-delimited editor text contains a suggestion.
    ///
    /// - Parameters:
    ///   - suggestion: The canonical discovered address to find.
    ///   - addressesText: The editor's newline-delimited address text.
    /// - Returns: `true` when any valid line canonicalizes to the suggestion.
    public func contains(
        _ suggestion: CmxPrivateNetworkAddress,
        in addressesText: String
    ) -> Bool {
        addressesText
            .split(whereSeparator: \.isNewline)
            .contains { line in
                guard let address = try? CmxIrohCustomPrivateAddress(String(line)) else {
                    return false
                }
                return address.value == suggestion.address
            }
    }
}
