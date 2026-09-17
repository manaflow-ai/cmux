/// An iOS-version range and its Mac compatibility requirements.
extension MobileMacCompatPolicy {
    /// One iOS-version tier and the Mac minimums it demands.
    public struct Tier: Equatable, Sendable {
        /// The inclusive minimum iOS marketing version this tier applies to.
        public let minIOSVersion: MobileMacAppVersion
        /// The optional inclusive maximum iOS marketing version. `nil` is
        /// open-ended, so one tier captures every version from its minimum
        /// upward without listing each patch release; a bound scopes the
        /// tier to a range (equal min and max pinpoints one version).
        public let maxIOSVersion: MobileMacAppVersion?
        /// The inclusive minimum stable-channel Mac marketing version.
        public let stableMinVersion: MobileMacAppVersion
        /// The minimum nightly-channel build; `nil` leaves nightly unconstrained.
        public let nightly: NightlyRequirement?

        /// Creates one tier of the policy.
        ///
        /// - Parameters:
        ///   - minIOSVersion: The inclusive minimum iOS version of the tier.
        ///   - maxIOSVersion: The optional inclusive maximum iOS version.
        ///   - stableMinVersion: The minimum stable-channel Mac version.
        ///   - nightly: The minimum nightly-channel build, or `nil`.
        public init(
            minIOSVersion: MobileMacAppVersion,
            maxIOSVersion: MobileMacAppVersion? = nil,
            stableMinVersion: MobileMacAppVersion,
            nightly: NightlyRequirement?
        ) {
            self.minIOSVersion = minIOSVersion
            self.maxIOSVersion = maxIOSVersion
            self.stableMinVersion = stableMinVersion
            self.nightly = nightly
        }
    }
}
