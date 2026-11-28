import Sentry

extension Breadcrumb {
    /// Replaces all data using the API shared by the Mac and iOS SDK pins.
    func replaceData(_ data: [String: Any]) {
        // Sentry 9.24.0 deprecates this setter in favor of per-key
        // `setData(value:key:)` but retains it. Whole-dictionary replacement
        // is kept because it also removes keys erased by scrubbing.
        self.data = data
    }
}
