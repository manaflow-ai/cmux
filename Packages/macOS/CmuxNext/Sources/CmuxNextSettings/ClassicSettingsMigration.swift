import Foundation

extension SettingsController {
    /// Moves classic cmux keys next reads under another name (hq#1870, cx-iy8b7).
    /// Returns whether it wrote.
    @discardableResult
    public func migrateClassicSettings() async throws -> Bool {
        false
    }
}
