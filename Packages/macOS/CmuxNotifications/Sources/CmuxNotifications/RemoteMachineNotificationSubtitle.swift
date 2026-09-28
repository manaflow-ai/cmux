import Foundation

/// Builds the subtitle for a notification that a remote machine produced.
public struct RemoteMachineNotificationSubtitle: Sendable {
    /// The longest producer-supplied detail kept before truncation.
    public static let maxDetailLength = 120
    /// The longest machine name kept before truncation.
    public static let maxMachineNameLength = 64

    private let format: String

    /// Creates a builder.
    ///
    /// - Parameter format: A localized format with two `%@` arguments: the
    ///   detail, then the machine name.
    public init(format: String) {
        self.format = format
    }

    /// The subtitle for a remote notification.
    ///
    /// - Parameters:
    ///   - explicit: The subtitle the remote producer supplied, if any.
    ///   - terminalTitle: The remote terminal's title, if known.
    ///   - machineName: The name of the machine that produced the notification.
    public func subtitle(explicit: String?, terminalTitle: String?, machineName: String) -> String {
        if let explicit { return explicit }
        guard let terminalTitle, !terminalTitle.isEmpty else { return machineName }
        return String(format: format, terminalTitle, machineName)
    }
}
