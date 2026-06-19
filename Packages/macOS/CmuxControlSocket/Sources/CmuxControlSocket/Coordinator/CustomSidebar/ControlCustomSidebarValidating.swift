public import Foundation

/// Validates custom sidebar files for control-socket commands.
public protocol ControlCustomSidebarValidating: Sendable {
    /// Validates every discovered sidebar, or one requested sidebar name.
    ///
    /// - Parameters:
    ///   - directory: Directory containing custom sidebar files.
    ///   - requestedName: Optional sidebar name to validate.
    /// - Returns: A control-socket validation report.
    func validate(directory: URL, name requestedName: String?) -> ControlCustomSidebarValidationReport
}
