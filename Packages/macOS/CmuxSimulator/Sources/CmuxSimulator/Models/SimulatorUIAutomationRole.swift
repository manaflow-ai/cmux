/// A normalized semantic role exposed to automation callers.
public enum SimulatorUIAutomationRole: String, Codable, Equatable, Sendable {
    /// The foreground application.
    case application
    /// An activatable button.
    case button
    /// A row or collection cell.
    case cell
    /// An image.
    case image
    /// One key in the software keyboard.
    case keyboardKey = "keyboard-key"
    /// A list or table.
    case list
    /// A menu.
    case menu
    /// An element whose native role has no more specific normalized role.
    case other
    /// A scrollable container.
    case scrollView = "scroll-view"
    /// A slider.
    case slider
    /// A binary switch or checkbox.
    case `switch`
    /// A tab.
    case tab
    /// Static text.
    case text
    /// An editable text field or text view.
    case textField = "text-field"
    /// The foreground application window.
    case window
}
