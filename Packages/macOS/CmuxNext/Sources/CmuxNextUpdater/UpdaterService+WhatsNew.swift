import Foundation

/// The what's-new card (R114): only on the first launch of a new build that
/// has human highlights, never on a fresh install.
extension UpdaterService {
    static let lastSeenBuildKey = "cmux.next.updates.lastSeenBuild"

    /// Red-test stub.
    @discardableResult
    public func loadWhatsNew() -> Task<Void, Never>? { nil }

    /// The card's x or a click that opened the changelog.
    public func dismissWhatsNew() {}
}
