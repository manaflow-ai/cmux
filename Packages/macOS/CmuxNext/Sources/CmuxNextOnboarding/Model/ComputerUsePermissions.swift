public import Foundation

/// The two macOS grants computer use needs, as the helper app
/// (cmux Computer Use) holds them: macOS attributes both to that app, not
/// to cmux.
public nonisolated struct ComputerUsePermissions: Sendable, Equatable {
    public var accessibility: Bool
    public var screenRecording: Bool
    /// The helper answered, but not in the protocol this build speaks (it
    /// refused `permissions_status` or its reply lacks the grants). The
    /// grants are then unknown; the step says the versions do not match.
    public var helperVersionMismatch: Bool
    /// Computer Use is off, so no helper runs and the grants are unknown;
    /// Allow turns it on first.
    public var isOff: Bool

    public init(accessibility: Bool, screenRecording: Bool, helperVersionMismatch: Bool = false, isOff: Bool = false) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.helperVersionMismatch = helperVersionMismatch
        self.isOff = isOff
    }

    public static let none = ComputerUsePermissions(accessibility: false, screenRecording: false)
    public static let helperVersionMismatch = ComputerUsePermissions(accessibility: false, screenRecording: false,
                                                                     helperVersionMismatch: true)
    public static let off = ComputerUsePermissions(accessibility: false, screenRecording: false, isOff: true)

    public var allGranted: Bool { accessibility && screenRecording }

    public func granted(_ pane: ComputerUsePermissionPane) -> Bool {
        switch pane {
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        }
    }
}
