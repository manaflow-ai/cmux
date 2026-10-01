import Foundation

/// The count a section header shows after its title: a plain number
/// ("My Devices 2") or preformatted usage ("Cloud Machines 1/50").
public struct CloudTreeGroupCount: Equatable, Sendable {
    /// Creates a header count with optional accessibility and limit information.
    /// - Parameters:
    ///   - text: Visible count text.
    ///   - accessibilityLabel: Spoken count, or nil to read the visible text.
    ///   - help: Header tooltip, or nil when no explanation is needed.
    ///   - isWarning: Whether to tint the count as a plan-limit warning.
    public init(text: String, accessibilityLabel: String? = nil, help: String? = nil, isWarning: Bool = false) {
        self.text = text
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.isWarning = isWarning
    }

    /// Creates a plain numeric count without plan-limit information.
    /// - Parameter count: Number of items in the group.
    public init(_ count: Int) {
        self.init(text: String(count))
    }

    /// Plan usage: VoiceOver hears "1 of 50 machines", and the count turns
    /// orange at the ceiling, where a free plan's help names the upgrade.
    /// - Parameter usage: Current machine usage and plan limits.
    public init(usage: CloudMachinesUsage) {
        self.init(
            text: usage.compactCount,
            accessibilityLabel: usage.countLabel,
            help: usage.help,
            isWarning: usage.isAtLimit
        )
    }

    /// Visible count text beside the section title.
    public let text: String
    /// What VoiceOver reads when the visible text is symbolic ("1 of 50
    /// machines", never "1 slash 50"); nil reads the text itself.
    public let accessibilityLabel: String?
    /// The header row's tooltip. The row owns it: the count's own view never hit-tests.
    public let help: String?
    /// Tints the count orange, e.g. a plan at its machine ceiling.
    public let isWarning: Bool
}
