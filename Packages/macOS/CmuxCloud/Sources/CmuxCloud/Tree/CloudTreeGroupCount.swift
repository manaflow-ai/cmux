import Foundation

/// The count a section header shows after its title: a plain number
/// ("My Devices 2") or preformatted usage ("Cloud Machines 1/50").
public struct CloudTreeGroupCount: Equatable, Sendable {
    public init(text: String, accessibilityLabel: String? = nil, help: String? = nil, isWarning: Bool = false) {
        self.text = text
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.isWarning = isWarning
    }

    public init(_ count: Int) {
        self.init(text: String(count))
    }

    public let text: String
    /// What VoiceOver reads when the visible text is symbolic ("1 of 50
    /// machines", never "1 slash 50"); nil reads the text itself.
    public let accessibilityLabel: String?
    public let help: String?
    /// Tints the count orange, e.g. a plan at its machine ceiling.
    public let isWarning: Bool
}
