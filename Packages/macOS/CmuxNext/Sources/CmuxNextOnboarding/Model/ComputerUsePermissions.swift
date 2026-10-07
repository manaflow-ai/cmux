public import Foundation

/// The two macOS grants computer use needs, as the helper app
/// (cmux Computer Use) holds them: macOS attributes both to that app, not
/// to cmux.
public nonisolated struct ComputerUsePermissions: Sendable, Equatable {
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public static let none = ComputerUsePermissions(accessibility: false, screenRecording: false)

    public var allGranted: Bool { accessibility && screenRecording }

    public func granted(_ pane: ComputerUsePermissionPane) -> Bool {
        switch pane {
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        }
    }
}
