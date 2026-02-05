import Foundation
import Combine

/// Type of panel content
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
}

/// Protocol for all panel types (terminal, browser, etc.)
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    /// Unique identifier for this panel
    var id: UUID { get }

    /// The type of panel
    var panelType: PanelType { get }

    /// Display title shown in tab bar
    var displayTitle: String { get }

    /// Optional SF Symbol icon name for the tab
    var displayIcon: String? { get }

    /// Whether the panel has unsaved changes
    var isDirty: Bool { get }

    /// Close the panel and clean up resources
    func close()

    /// Focus the panel for input
    func focus()

    /// Unfocus the panel
    func unfocus()
}

/// Extension providing default implementations
extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }
}
