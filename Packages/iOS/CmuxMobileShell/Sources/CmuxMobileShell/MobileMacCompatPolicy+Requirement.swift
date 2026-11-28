/// Requirements for one iOS distribution build kind.
extension MobileMacCompatPolicy {
    /// Stable and nightly Mac version floors for one iOS build kind.
    public struct Requirement: Equatable, Sendable {
        /// The inclusive minimum stable-channel Mac marketing version.
        public let stableMinVersion: MobileMacAppVersion
        /// The minimum nightly-channel Mac build, or `nil` when unconstrained.
        public let nightly: NightlyRequirement?

        /// Creates requirements for one build kind.
        /// - Parameters:
        ///   - stableMinVersion: The minimum stable-channel Mac version.
        ///   - nightly: The minimum nightly-channel build, or `nil`.
        public init(stableMinVersion: MobileMacAppVersion, nightly: NightlyRequirement? = nil) {
            self.stableMinVersion = stableMinVersion
            self.nightly = nightly
        }
    }
}
