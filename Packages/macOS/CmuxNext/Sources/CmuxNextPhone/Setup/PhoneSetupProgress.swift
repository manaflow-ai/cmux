public import Foundation

/// How far a running setup download is, read from the tool's own output
/// (`xcodebuild -downloadPlatform iOS` prints lines such as
/// `Downloading iOS 18.1 Simulator (22B81): 12.4% (1.04 GB of 8.39 GB)`).
public struct PhoneSetupProgress: Sendable, Hashable {
    /// 0...1, or nil while the tool has not reported a percentage yet.
    public var fraction: Double?
    /// "1.04 GB of 8.39 GB" when the tool printed it.
    public var amount: String?

    public init(fraction: Double? = nil, amount: String? = nil) {
        self.fraction = fraction
        self.amount = amount
    }

    /// The progress after `output` (a chunk that may hold several lines or
    /// `\r`-separated updates); the last percentage in it wins. Unchanged
    /// when the chunk has none.
    public func reading(_ output: String) -> PhoneSetupProgress {
        var next = self
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let percent = line.range(of: #"[0-9]+(\.[0-9]+)?(?=\s?%)"#, options: .regularExpression),
                  let value = Double(line[percent]) else { continue }
            next.fraction = min(max(value / 100, 0), 1)
            if let amount = line.range(of: #"(?<=\()[0-9.]+\s?[KMGT]?B of [0-9.]+\s?[KMGT]?B(?=\))"#, options: .regularExpression) {
                next.amount = String(line[amount])
            }
        }
        return next
    }
}
