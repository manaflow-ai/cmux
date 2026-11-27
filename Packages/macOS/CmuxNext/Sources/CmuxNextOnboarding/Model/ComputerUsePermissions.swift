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
    /// The helper did not start or stopped answering: no Allow can help until it runs again.
    public var helperFailed: Bool
    /// The helper is starting and its grants are being read: they show as missing until it answers,
    /// and nothing is started on them (an entry's Allow waits for the answer).
    public var isReading: Bool

    public init(accessibility: Bool, screenRecording: Bool, helperVersionMismatch: Bool = false, isOff: Bool = false, helperFailed: Bool = false,
                isReading: Bool = false) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.helperVersionMismatch = helperVersionMismatch
        self.isOff = isOff
        self.helperFailed = helperFailed
        self.isReading = isReading
    }

    public static let none = ComputerUsePermissions(accessibility: false, screenRecording: false)
    public static let helperVersionMismatch = ComputerUsePermissions(accessibility: false, screenRecording: false,
                                                                     helperVersionMismatch: true)
    public static let helperFailed = ComputerUsePermissions(accessibility: false, screenRecording: false, helperFailed: true)
    public static let off = ComputerUsePermissions(accessibility: false, screenRecording: false, isOff: true)
    public static let reading = ComputerUsePermissions(accessibility: false, screenRecording: false, isReading: true)

    public func granted(_ pane: ComputerUsePermissionPane) -> Bool {
        switch pane {
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        }
    }
}
