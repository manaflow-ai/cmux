/// The data needed to explain a rejected Mac connection.
extension MobileMacCompatPolicy {
    /// Why a connected Mac was refused, carrying everything the failure copy
    /// needs: the channel, the Mac's reported version (nil when the Mac
    /// predates version reporting), and the tier minimum for that channel.
    public struct Violation: Equatable, Sendable {
        /// The release lane whose minimum the Mac missed.
        public let channel: Channel
        /// The Mac's reported version, or `nil` when it predates reporting.
        public let macAppVersion: String?
        /// The minimum version to present: the stable minimum, or the nightly
        /// minimum rendered in the nightly stamp grammar.
        public let requiredVersionDisplay: String
    }
}
