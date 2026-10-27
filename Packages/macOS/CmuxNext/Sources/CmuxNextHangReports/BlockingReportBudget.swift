public import CmuxNextCompat
public import Foundation

/// How many blocking call sites one launch may send to crash reporting as non-fatal events: at most
/// ``perLaunch`` per launch and one per site per ``perSiteInterval`` (the last-sent times persist
/// across launches, plans/cmux-next/chrome-parity/p02-threads.md "Sentry volume and consent").
///
/// A pure value: the app's `BlockingReportSink` holds one, loads ``lastSent`` once and saves it
/// after each admitted site.
///
/// ```swift
/// var budget = BlockingReportBudget(lastSent: saved)
/// if budget.admit(site: BlockingReportBudget.site(of: violation), now: Date()) { send(violation) }
/// ```
public nonisolated struct BlockingReportBudget: Sendable, Equatable {
    /// The most sites one launch sends.
    public static let perLaunch = 5
    /// The shortest time between two sends of one site (24 h).
    public static let perSiteInterval: TimeInterval = 24 * 60 * 60

    /// Sites sent this launch.
    public private(set) var sentThisLaunch = 0
    /// When each site was last sent, by ``site(of:)``; only sends younger than ``perSiteInterval``.
    public private(set) var lastSent: [String: Date]

    /// Makes the value from the last-sent times a previous launch saved.
    public init(lastSent: [String: Date] = [:]) {
        self.lastSent = lastSent
    }

    /// Whether `site` may be sent at `now`; when it may, counts it and records the time.
    ///
    /// A last-sent time later than `now` (the clock moved back) does not hold the site.
    public mutating func admit(site: String, now: Date) -> Bool {
        guard sentThisLaunch < Self.perLaunch else { return false }
        if let last = lastSent[site], Self.isRecent(last, now: now) { return false }
        sentThisLaunch += 1
        lastSent = lastSent.filter { Self.isRecent($0.value, now: now) }
        lastSent[site] = now
        return true
    }

    /// The site's identity: its kind, its context and every frame (image UUID + offset), as 16 hex
    /// digits of a 64-bit FNV-1a hash. The seam frame alone would merge every caller of one seam.
    public static func site(of violation: BlockingViolation) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(truncatingIfNeeded: byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        violation.kind.rawValue.utf8.forEach(mix)
        mix(0)  // separates the kind from the context
        violation.context.rawValue.utf8.forEach(mix)
        for frame in violation.frames {
            // SAFETY: reads the 16 bytes of the UUID tuple and the 8 of the offset, both copied by value, only inside
            // each closure.
            unsafe withUnsafeBytes(of: frame.imageUUID.uuid) { unsafe $0.forEach(mix) }
            // SAFETY: as above.
            unsafe withUnsafeBytes(of: frame.offset.littleEndian) { unsafe $0.forEach(mix) }
        }
        return String(("0000000000000000" + String(hash, radix: 16)).suffix(16))
    }

    private static func isRecent(_ sent: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(sent)
        return age >= 0 && age < perSiteInterval
    }
}
