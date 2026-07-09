import Foundation

/// Localized failure messages the interpreter returns. These are resolved
/// app-side with `String(localized:)` (so they bind to the app bundle's
/// catalog) and injected, keeping localization out of the package bundle.
public struct RightSidebarRemoteStrings: Sendable {
    /// "Right sidebar target not found".
    public let targetNotFound: String
    /// "Right sidebar state not available".
    public let stateUnavailable: String
    /// "Right sidebar not available".
    public let unavailable: String
    /// "Failed to focus right sidebar".
    public let focusFailed: String
    /// Builds "Right sidebar mode '<mode>' is not available" for a given mode.
    public let modeUnavailable: @Sendable (RightSidebarMode) -> String

    /// Creates the injected message set.
    public init(
        targetNotFound: String,
        stateUnavailable: String,
        unavailable: String,
        focusFailed: String,
        modeUnavailable: @escaping @Sendable (RightSidebarMode) -> String
    ) {
        self.targetNotFound = targetNotFound
        self.stateUnavailable = stateUnavailable
        self.unavailable = unavailable
        self.focusFailed = focusFailed
        self.modeUnavailable = modeUnavailable
    }
}
