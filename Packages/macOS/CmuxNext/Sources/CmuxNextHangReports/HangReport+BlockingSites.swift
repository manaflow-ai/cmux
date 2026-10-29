import CryptoKit
import Foundation

extension HangReport {
    /// The most blocking call sites one report names.
    public static let maxBlockingSites = 20

    /// One main-thread blocking call site in a report's `blocking_sites`: its id, what it
    /// waited on, how many calls ended there and their wall time since the last report. Counts only: the id is a
    /// hash, so no path, file or symbol leaves the Mac, and `lab.py field --sites-from <checkout>` names the line
    /// by hashing every line of that build's Swift sources.
    ///
    /// Chrome's `IOJankMonitoringWindow` (base/threading/scoped_blocking_call_internal.cc) reports how long the UI
    /// thread blocked; this also says where, by site.
    public struct BlockingSiteCount: Codable, Sendable, Equatable {
        /// ``siteID(location:)`` of the call site.
        public var site: String
        /// The `BlockingKind` raw value.
        public var kind: String
        /// Calls that ended at the site.
        public var count: Int
        /// Their wall time, in milliseconds (a call inside another timed call counts without time).
        public var totalMs: Int

        /// Makes the value from its parts.
        public init(site: String, kind: String, count: Int, totalMs: Int) {
            self.site = site
            self.kind = kind
            self.count = count
            self.totalMs = totalMs
        }

        private enum CodingKeys: String, CodingKey {
            case site, kind, count
            case totalMs = "total_ms"
        }

        /// The id of a detector site at `location` (`BlockingSite.location`, `Module/File.swift:line`): the first
        /// 8 bytes of SHA-256 over the location's UTF-8, as 16 lowercase hex digits. A file and line keep their id
        /// across builds, so the counts of two builds compare.
        public static func siteID(location: String) -> String {
            SHA256.hash(data: Data(location.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }
}
