import Foundation

/// Persists usage-tip eligibility, opt-out state, and permanently seen tip identifiers.
///
/// The app has one main-actor usage-tip controller, so seen-ID read/modify/write
/// operations are serialized by that owner. The store itself remains a stateless,
/// synchronous value because `UserDefaults` is thread-safe and launch eligibility
/// must be captured before the first main window appears.
public struct UsageTipsStore: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let accountKeys = AccountCatalogSection()
    private let appKeys = AppCatalogSection()

    /// Creates a usage-tip store backed by the supplied defaults suite.
    ///
    /// - Parameter defaults: The isolated or standard `UserDefaults` suite to use.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether usage tips are enabled.
    public var isEnabled: Bool {
        appKeys.showUsageTips.value(in: defaults)
    }

    /// Whether the welcome experience was completed before this read.
    public var hasShownWelcome: Bool {
        accountKeys.welcomeShown.value(in: defaults)
    }

    /// The stable identifiers that the user permanently acknowledged.
    public var seenTipIDs: Set<String> {
        Set(appKeys.seenUsageTipIDs.value(in: defaults))
    }

    /// Persists whether usage tips are enabled.
    ///
    /// - Parameter isEnabled: `true` to allow future tips; `false` to suppress them.
    public func setEnabled(_ isEnabled: Bool) {
        appKeys.showUsageTips.set(isEnabled, in: defaults)
    }

    /// Permanently records a tip identifier as seen without disturbing other identifiers.
    ///
    /// - Parameter id: The stable catalog identifier to record.
    public func markSeen(_ id: String) {
        var updated = seenTipIDs
        updated.insert(id)
        appKeys.seenUsageTipIDs.set(updated.sorted(), in: defaults)
    }
}
