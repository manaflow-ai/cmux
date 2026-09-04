import Foundation

/// The dimension used to partition a History timeline.
public enum VaultHistoryGroupKey: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Browser-history-style rolling and calendar date buckets.
    case date
    /// Runtime workspace identity.
    case workspace
    /// Runtime window identity.
    case window
    /// Locale-independent agent identity.
    case agent
    /// History event category.
    case kind

    /// Stable raw-value identity used by SwiftUI controls.
    public var id: String { rawValue }
}
