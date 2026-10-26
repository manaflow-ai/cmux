#if DEBUG || CMUX_BENCH_HOOKS
import Darwin
import Foundation
import ObjectiveC

extension InputDirtyRecorder {
    /// `debug.input dirty`: what the installed recorder saw (snake_case keys when encoded).
    public nonisolated struct Report: Codable, Sendable, Equatable {
        public var installed: Bool
        /// Dirty calls recorded in input turns (nested calls not counted).
        public var dirtyCalls: Int
        /// Of those, the calls on a view outside the event target's subtree or in another window.
        public var offTargetCalls: Int
        /// Calls of a new site after ``InputDirtyRecorder/siteLimit`` sites were kept.
        public var droppedCalls: Int
        public var siteLimit: Int
        public var turns: Turns
        /// Off-target sites first, then by count.
        public var sites: [SiteRow]

        enum CodingKeys: String, CodingKey {
            case installed, turns, sites
            case dirtyCalls = "dirty_calls"
            case offTargetCalls = "off_target_calls"
            case droppedCalls = "dropped_calls"
            case siteLimit = "site_limit"
        }
    }

    /// The input turns: how many closed, and the kept ones' dispatch and commit times.
    public nonisolated struct Turns: Codable, Sendable, Equatable {
        public var closed: Int
        public var kept: Int
        public var dispatchMs: Distribution
        /// The `.beforeWaiting` stage of the turn's pass: AppKit's display cycle and Core Animation's commit.
        public var commitMs: Distribution
        /// The kept turns, oldest first.
        public var recent: [TurnRow]

        enum CodingKeys: String, CodingKey {
            case closed, kept, recent
            case dispatchMs = "dispatch_ms"
            case commitMs = "commit_ms"
        }
    }

    /// Nearest-rank percentiles of a set of milliseconds (zeros when empty).
    public nonisolated struct Distribution: Codable, Sendable, Equatable {
        public var p50: Double
        public var p95: Double
        public var p99: Double
        public var max: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            func rank(_ quantile: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let index = Int((Double(sorted.count) * quantile).rounded(.up)) - 1
                return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
            }
            p50 = rank(0.5)
            p95 = rank(0.95)
            p99 = rank(0.99)
            max = sorted.last ?? 0
        }
    }

    /// One closed turn.
    public nonisolated struct TurnRow: Codable, Sendable, Equatable {
        public var kinds: [String]
        public var events: Int
        public var dispatchMs: Double
        public var commitMs: Double
        public var dirtyCalls: Int
        public var offTargetCalls: Int

        enum CodingKeys: String, CodingKey {
            case kinds, events
            case dispatchMs = "dispatch_ms"
            case commitMs = "commit_ms"
            case dirtyCalls = "dirty_calls"
            case offTargetCalls = "off_target_calls"
        }
    }

    /// One site: a dirtied class at a placement from one stack.
    public nonisolated struct SiteRow: Codable, Sendable, Equatable {
        /// The dirtied view's class (or the layer's owning view's); nil for a layer no view owns.
        public var viewClass: String?
        /// The layer's class for a layer call; nil for a view call.
        public var layerClass: String?
        public var placement: String
        public var offTarget: Bool
        public var calls: [String]
        public var turnKinds: [String]
        public var phases: [String]
        public var count: Int
        public var turns: Int
        /// Innermost first, the recorder's own frames left out.
        public var frames: [Frame]

        enum CodingKeys: String, CodingKey {
            case placement, calls, phases, count, turns, frames
            case viewClass = "view_class"
            case layerClass = "layer_class"
            case offTarget = "off_target"
            case turnKinds = "turn_kinds"
        }
    }

    /// One return address: its image, its offset in the image (the script resolves file and line
    /// against the build's dSYM) and the nearest exported symbol when the image has one.
    public nonisolated struct Frame: Codable, Sendable, Equatable {
        public var image: String?
        public var offset: UInt
        public var symbol: String?
    }

    /// The report of `snapshot`: class names and frames resolved here, off the main thread
    /// (`dladdr` takes dyld's lock).
    @concurrent
    nonisolated static func resolve(_ snapshot: Snapshot) async -> Report {
        var resolver = FrameResolver()
        let ordered = snapshot.sites.indices.sorted { lhs, rhs in
            let left = snapshot.sites[lhs], right = snapshot.sites[rhs]
            if left.key.placement.isOffTarget != right.key.placement.isOffTarget { return left.key.placement.isOffTarget }
            return left.count > right.count
        }
        let rows = ordered.prefix(snapshot.limit).map { index -> SiteRow in
            let site = snapshot.sites[index]
            let start = index * stackDepth
            let addresses = Array(snapshot.stacks[start..<(start + site.stackCount)])
            return SiteRow(
                viewClass: className(site.key.viewClass), layerClass: className(site.key.layerClass),
                placement: site.key.placement.key, offTarget: site.key.placement.isOffTarget,
                calls: DirtyKind.allCases.filter { site.kinds & $0.bit != 0 }.map(\.key),
                turnKinds: TurnKind.allCases.filter { site.turnKinds & $0.bit != 0 }.map(\.key),
                phases: Phase.allCases.filter { site.phases & $0.bit != 0 }.map(\.key),
                count: site.count, turns: site.turns, frames: resolver.frames(addresses)
            )
        }
        let turns = chronological(snapshot.turns, closed: snapshot.turnsClosed)
        let ms = { (nanos: UInt64) in Double(nanos) / 1_000_000 }
        return Report(
            installed: snapshot.installed, dirtyCalls: snapshot.dirtyCalls, offTargetCalls: snapshot.offTargetCalls,
            droppedCalls: snapshot.droppedCalls, siteLimit: siteLimit,
            turns: Turns(
                closed: snapshot.turnsClosed, kept: turns.count,
                dispatchMs: Distribution(turns.map { ms($0.dispatchNanos) }),
                commitMs: Distribution(turns.map { ms($0.commitNanos) }),
                recent: turns.map { turn in
                    TurnRow(kinds: TurnKind.allCases.filter { turn.kinds & $0.bit != 0 }.map(\.key), events: turn.events,
                            dispatchMs: ms(turn.dispatchNanos), commitMs: ms(turn.commitNanos),
                            dirtyCalls: turn.dirtyCalls, offTargetCalls: turn.offTargetCalls)
                }
            ),
            sites: rows
        )
    }

    /// The ring's turns oldest first.
    nonisolated static func chronological(_ ring: [TurnRecord], closed: Int) -> [TurnRecord] {
        guard closed > ring.count, !ring.isEmpty else { return ring }
        let oldest = closed % ring.count
        return Array(ring[oldest...] + ring[..<oldest])
    }

    /// The name of a class kept as its pointer's bits; nil for 0.
    nonisolated static func className(_ bits: UInt) -> String? {
        guard bits != 0 else { return nil }
        return String(reflecting: unsafeBitCast(bits, to: AnyClass.self))
    }

    /// Return addresses to frames; drops the recorder's own leading frames where names show them.
    nonisolated struct FrameResolver {
        private var images: [UInt: String] = [:]

        mutating func frames(_ addresses: [UInt]) -> [Frame] {
            let all = addresses.map { frame($0) }
            let own = all.prefix { frame in
                guard let symbol = frame.symbol else { return false }
                return Self.ownMarkers.contains { symbol.contains($0) }
            }
            return Array(all.dropFirst(own.count))
        }

        /// Substrings of the demangled names of the recorder's capture path (the hook, its block
        /// thunk, the recorder's capture and the runtime calls between them).
        static let ownMarkers = [
            "CmuxNextInput.InputDirtyRecorder.", "CmuxNextInput.InputDirtyHook.", "thunk for", "assumeIsolated",
            "withUnsafeTemporaryAllocation", "withMemoryRebound", "backtrace",
        ]

        private mutating func frame(_ address: UInt) -> Frame {
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0,
                  let base = info.dli_fbase else { return Frame(image: nil, offset: address, symbol: nil) }
            let key = UInt(bitPattern: base)
            if images[key] == nil {
                images[key] = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            }
            return Frame(image: images[key], offset: address &- key,
                         symbol: info.dli_sname.map { Self.demangle(String(cString: $0)) })
        }

        private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                     UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

        private static func demangle(_ name: String) -> String {
            guard name.hasPrefix("$s") || name.hasPrefix("_$s"),
                  let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return name }
            let swiftDemangle = unsafeBitCast(symbol, to: Demangle.self)
            return name.withCString { raw in
                guard let result = swiftDemangle(raw, strlen(raw), nil, nil, 0) else { return name }
                defer { free(result) }
                return String(cString: result)
            }
        }
    }
}
#endif
