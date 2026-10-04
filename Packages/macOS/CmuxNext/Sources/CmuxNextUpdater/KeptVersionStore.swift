public import Foundation

/// Previous app versions kept for rollback (`updates.keepPreviousVersions`):
/// `<root>/<build>/<App>.app`, cloned (APFS clonefile, no extra disk until
/// blocks change) right before Sparkle installs over the running bundle.
nonisolated public struct KeptVersionStore: Sendable {
    public let root: URL
    /// The signing team of a bundle (SecStaticCode in the app; injected in tests).
    public let teamID: @Sendable (URL) -> String?

    public init(root: URL, teamID: @escaping @Sendable (URL) -> String?) {
        self.root = root
        self.teamID = teamID
    }

    /// Keeps `bundle` as `build`, then prunes to the newest `limit`.
    public func keep(bundle: URL, build: String, limit: Int) throws {}

    /// Kept versions, newest build first.
    public func list() -> [KeptVersion] { [] }
}
