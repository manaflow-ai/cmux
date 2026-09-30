/// The single admission outcome for an authenticated Mac: channel/tag
/// compatibility (``MobileMacBuildCompatibilityPolicy``) first, then the
/// release-lane version floor (``MobileMacCompatPolicy``).
enum MacBuildAdmissionVerdict: Equatable {
    /// The Mac may be used by this build.
    case allowed
    /// The Mac belongs to a lane this build never admits.
    case buildIncompatible
    /// The Mac's app version is below this build's minimum for its lane.
    case macAppVersionTooOld(MobileMacCompatPolicy.Violation)
}
