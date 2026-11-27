/// Precedence and write permission for one flag in the current build.
enum CmuxFeatureFlagOverridePolicy: Equatable, Sendable {
    case remoteFirst
    case localFirst
    case disabled
}
