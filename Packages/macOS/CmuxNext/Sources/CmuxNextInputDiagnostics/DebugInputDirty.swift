#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Foundation

/// The reply of `debug.input` action `dirty`. Class names and image offsets only: no user text.
public nonisolated struct DebugInputDirty: Sendable, Encodable, Equatable {
    /// The recorder is installed (every reply but the one of a reset).
    public var installed: Bool
    /// This request installed it: its rows are empty, the next request's are the turns between.
    public var installedNow: Bool
    public var sinceLaunch: Bool
    /// Turns ended, by input (`key`, `click`, `scroll`).
    public var turns: [String: Int]
    /// Dirty calls recorded in turns.
    public var calls: Int
    /// The calls whose view is off the target (`outside`, `other_window`, `no_view`).
    public var offTargetCalls: Int
    /// Calls at a site past ``siteLimit``.
    public var sitesOverflow: Int
    public var siteLimit: Int
    /// The commit pass that ended each turn (AppKit's display cycle and the Core Animation commit), by
    /// input, over the newest ``turnLimit`` turns.
    public var commitPass: [String: Distribution]
    /// Dirty calls per turn, by input, over the same turns.
    public var callsPerTurn: [String: Distribution]
    public var turnLimit: Int
    /// One row per site: off-target rows first, then the most calls.
    public var rows: [Row]

    enum CodingKeys: String, CodingKey {
        case installed, installedNow = "installed_now", sinceLaunch = "since_launch", turns, calls
        case offTargetCalls = "off_target_calls", sitesOverflow = "sites_overflow", siteLimit = "site_limit"
        case commitPass = "commit_pass_ms", callsPerTurn = "calls_per_turn", turnLimit = "turn_limit", rows
    }

    /// Nearest-rank percentiles of one set of values.
    public nonisolated struct Distribution: Sendable, Encodable, Equatable {
        public var n: Int
        public var p50: Double
        public var p95: Double
        public var p99: Double
        public var max: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let rank = { (p: Double) in sorted[Int((p * Double(sorted.count - 1)).rounded())] }
            n = sorted.count
            p50 = rank(0.50)
            p95 = rank(0.95)
            p99 = rank(0.99)
            max = sorted[sorted.count - 1]
        }
    }

    /// One site.
    public nonisolated struct Row: Sendable, Encodable, Equatable {
        /// `view.needs_display`, `view.needs_display_in_rect`, `view.needs_layout`,
        /// `view.needs_update_constraints`, `layer.needs_layout`, `layer.needs_display` or
        /// `layer.needs_display_in_rect`.
        public var call: String
        /// The receiver's class (a view, or a layer).
        public var objectClass: String
        /// The view the receiver draws for; nil for a layer no view hosts.
        public var viewClass: String?
        /// `target`, `ancestor`, `outside`, `other_window`, `no_view` or `no_target`.
        public var relation: String
        public var offTarget: Bool
        public var count: Int
        /// The inputs of the turns the site's calls ran in.
        public var kinds: [String]
        /// The first call's stack, innermost first (the recorder's own frames first).
        public var stack: [Frame]

        enum CodingKeys: String, CodingKey {
            case call, objectClass = "object_class", viewClass = "view_class", relation, offTarget = "off_target", count, kinds, stack
        }
    }

    /// One return address as image + offset, to symbolicate with the image's dSYM.
    public nonisolated struct Frame: Sendable, Encodable, Equatable {
        public var image: String
        public var imageUUID: String?
        /// The return address minus the image's load address (the address itself when unresolved).
        public var offset: UInt64
        /// `dladdr`'s nearest exported symbol before the call (mangled).
        public var nearestSymbol: String?

        enum CodingKeys: String, CodingKey {
            case image, imageUUID = "image_uuid", offset, nearestSymbol = "nearest_symbol"
        }
    }

    init(_ copy: InputDirtyCopy) {
        let window = copy.window
        installed = copy.installed
        installedNow = copy.installedNow
        sinceLaunch = copy.sinceLaunch
        turns = Dictionary(uniqueKeysWithValues: window.turns.map { ($0.key.rawValue, $0.value) })
        calls = window.calls
        offTargetCalls = window.offTargetCalls
        sitesOverflow = window.sitesOverflow
        siteLimit = copy.siteLimit
        turnLimit = copy.turnLimit
        var commitPass: [String: Distribution] = [:]
        var callsPerTurn: [String: Distribution] = [:]
        for kind in InputDirtyTurnKind.allCases {
            let passes = window.passes.filter { $0.kind == kind }
            commitPass[kind.rawValue] = Distribution(passes.map { Double($0.nanos) / 1e6 })
            callsPerTurn[kind.rawValue] = Distribution(passes.map { Double($0.calls) })
        }
        self.commitPass = commitPass
        self.callsPerTurn = callsPerTurn
        var resolver = ImageOffsetResolver()
        var frames: [UInt: Frame] = [:]
        let resolve = { (address: UInt) -> Frame in
            if let known = frames[address] { return known }
            let frame = resolver.resolve(address).map {
                Frame(image: $0.image.name, imageUUID: $0.image.uuid?.uuidString, offset: UInt64($0.offset), nearestSymbol: $0.nearestSymbol)
            } ?? Frame(image: "?", imageUUID: nil, offset: UInt64(address), nearestSymbol: nil)
            frames[address] = frame
            return frame
        }
        rows = window.sites.values.map { site in
            Row(call: site.call.name, objectClass: site.objectClass, viewClass: site.viewClass, relation: site.relation.rawValue,
                offTarget: site.relation.isOffTarget, count: site.count,
                kinds: InputDirtyTurnKind.allCases.filter { site.kinds.contains($0) }.map(\.rawValue),
                stack: site.stack.map(resolve))
        }.sorted { ($0.offTarget ? 0 : 1, -$0.count, $0.call, $0.objectClass) < ($1.offTarget ? 0 : 1, -$1.count, $1.call, $1.objectClass) }
    }
}
#endif
