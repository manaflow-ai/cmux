/// The nightly-channel minimum used by one Mac compatibility tier.
extension MobileMacCompatPolicy {
    /// The minimum nightly-channel build for one tier.
    public struct NightlyRequirement: Equatable, Sendable {
        /// The nightly stamp's base version at the minimum.
        public let minBaseVersion: MobileMacAppVersion
        /// The minimum monotonic nightly build counter, applied only when the
        /// stamp's base equals ``minBaseVersion`` (a greater base is newer).
        public let minBuild: UInt64

        /// Creates a nightly minimum from its base version and counter.
        ///
        /// - Parameters:
        ///   - minBaseVersion: The nightly stamp's base version at the minimum.
        ///   - minBuild: The minimum monotonic nightly build counter.
        public init(minBaseVersion: MobileMacAppVersion, minBuild: UInt64) {
            self.minBaseVersion = minBaseVersion
            self.minBuild = minBuild
        }
    }
}
