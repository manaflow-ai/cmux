import Sentry

extension Breadcrumb {
    /// Replaces all data using the API shared by the Mac and iOS SDK pins.
    func replaceData(_ data: [String: Any]) {
        // macOS pins Sentry 9.3.0, which has no per-key setter. Newer SDKs
        // deprecate this setter but retain it; keep that compatibility here.
        // Whole-dictionary replacement also removes keys erased by scrubbing.
        self.data = data
    }
}
