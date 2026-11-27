import Foundation

/// Verifies the code in a downloaded Chromium runtime immediately before it
/// is loaded. Returning an item name refuses the runtime.
protocol CEFCodeSignatureChecking: Sendable {
    nonisolated func invalidItem(in layout: CEFRuntimeLayout, teamID: String) -> String?
}
