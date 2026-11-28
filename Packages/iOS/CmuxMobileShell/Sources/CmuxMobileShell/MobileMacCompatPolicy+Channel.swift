import Foundation

/// The release lane to which a Mac version floor applies.
extension MobileMacCompatPolicy {
    /// The Mac release channel a version constraint applies to.
    public enum Channel: Equatable, Sendable {
        /// The stable release lane (`default` and legacy untagged Macs).
        case stable
        /// The nightly release lane.
        case nightly

        /// Resolves the constrained lane for an authenticated Mac instance
        /// tag. Development tags, `rc`, and `staging` are outside this policy.
        /// A missing tag is the pre-0.64.18 stable release lane.
        public init?(instanceTag: String?) {
            let normalized = instanceTag?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalized == nil || normalized == "" || normalized == "default" {
                self = .stable
            } else if normalized == "nightly" {
                self = .nightly
            } else {
                return nil
            }
        }
    }
}
