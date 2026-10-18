/// A coarse duration, so latency and dwell time aggregate without raw timings.
public enum DurationBucket: String, Sendable, CaseIterable {
    case under1s = "lt_1s"
    case from1to3s = "1s_3s"
    case from3to10s = "3s_10s"
    case from10to30s = "10s_30s"
    case from30to60s = "30s_60s"
    case from1to3m = "1m_3m"
    case from3to10m = "3m_10m"
    case from10to60m = "10m_60m"
    case from1to24h = "1h_24h"
    case from1to7d = "1d_7d"
    case over7d = "gt_7d"

    /// The bucket containing `seconds`. Negative values count as zero.
    public init(seconds: Double) {
        switch max(0, seconds) {
        case ..<1: self = .under1s
        case ..<3: self = .from1to3s
        case ..<10: self = .from3to10s
        case ..<30: self = .from10to30s
        case ..<60: self = .from30to60s
        case ..<180: self = .from1to3m
        case ..<600: self = .from3to10m
        case ..<3_600: self = .from10to60m
        case ..<86_400: self = .from1to24h
        case ..<604_800: self = .from1to7d
        default: self = .over7d
        }
    }
}
