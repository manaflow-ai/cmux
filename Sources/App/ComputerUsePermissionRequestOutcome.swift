/// A macOS permission owned by the standalone Computer Use helper.
enum ComputerUseSystemPermission: String, Hashable, Sendable {
    case accessibility
    case screenRecording = "screen_recording"
}

/// Whether the helper accepted a host request to raise a native permission prompt.
///
/// `accepted` describes dispatch to macOS, not the user's permission choice.
/// The helper-authoritative permission probe remains the source of truth.
enum ComputerUsePermissionRequestOutcome: Equatable, Sendable {
    case accepted
    case rejected
    case unknown
}
