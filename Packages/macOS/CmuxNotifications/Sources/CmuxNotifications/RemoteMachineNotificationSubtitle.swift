import Foundation

/// Builds the subtitle for a notification that a remote machine produced.
///
/// The machine name always shows, so a remote producer cannot make its
/// notification look like it came from this Mac.
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
        let machine = capped(singleLine(machineName), to: Self.maxMachineNameLength)
        let detail = [explicit, terminalTitle].lazy
            .compactMap { $0 }
            .map { capped(singleLine($0), to: Self.maxDetailLength) }
            .first { !$0.isEmpty }
        guard let detail else { return machine }
        return String(format: format, detail, machine)
    }

    /// `text` with line breaks, control characters and bidirectional
    /// overrides removed, so it cannot reorder or push out the machine name.
    private func singleLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                continue
            default:
                let breaks = scalar.properties.generalCategory == .control
                    || CharacterSet.newlines.contains(scalar)
                scalars.append(breaks ? " " : scalar)
            }
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private func capped(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
