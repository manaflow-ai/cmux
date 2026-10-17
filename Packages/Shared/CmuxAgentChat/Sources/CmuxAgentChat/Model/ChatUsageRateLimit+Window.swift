import Foundation

extension ChatUsageRateLimit {
    /// One rolling allowance window.
    public struct Window: Sendable, Equatable, Codable {
        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
        /// Percentage of the window's allowance used, 0 to 100.
        public var usedPercent: Double

        /// Length of the rolling window in minutes.
        public var windowMinutes: Int?

        /// When the window resets, when the provider says.
        public var resetsAt: Date?

        /// Creates a window reading.
        ///
        /// - Parameters:
        ///   - usedPercent: Percentage of the allowance used.
        ///   - windowMinutes: Window length in minutes.
        ///   - resetsAt: When the window resets.
        public init(usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }
}
