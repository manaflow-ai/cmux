public import Foundation

extension Duration {
    /// The duration in whole nanoseconds, clamped to `Int64`, for the hover rules' C ABI
    /// (cmux-motion `hover`, durations in signed nanoseconds).
    package nonisolated var hoverNanoseconds: Int64 {
        let parts = components
        let (whole, overflow) = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return parts.seconds < 0 ? .min : .max }
        let (sum, sumOverflow) = whole.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
        return sumOverflow ? (whole < 0 ? .min : .max) : sum
    }

    /// A duration of `nanoseconds` from the hover rules' C ABI.
    package nonisolated init(hoverNanoseconds nanoseconds: Int64) {
        self = .nanoseconds(nanoseconds)
    }
}
