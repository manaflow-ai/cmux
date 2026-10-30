#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Foundation

/// The fold's tables of ``InputTurnHopRecorder``: hops by site, since launch and since the last
/// reset, each at most ``InputTurnHopRecorder/siteLimit`` sites. Only the fold (under the
/// recorder's lock, never on the main thread) touches it.
struct HopSites {
    /// The most resolved addresses cached; past it the cache starts over, between two records.
    static let resolvedLimit = 4096

    /// The image that calls the Swift lane's producer (``HopFrameResolver/FrameKind/entry``).
    private let entry: String
    private var resolver = ImageOffsetResolver()
    private var resolved: [UInt: ImageOffsetResolver.Resolved?] = [:]
    private var sinceLaunch = Window()
    private var sinceReset = Window()
    private var droppedAtReset: UInt64 = 0

    init(entry: String) {
        self.entry = entry
    }

    /// A site: a Swift job's frame address, an unresolved site address, a Swift stack with no site
    /// (no entry frame, or none past the runtime frames), a sampled callout's frame address, or the
    /// stretch of unsampled callouts.
    enum Key: Hashable {
        case frame(UInt)
        case unresolved(UInt)
        case truncated
        case noStack
        case calloutFrame(UInt)
        case callout(InputTurnHopRecorder.CalloutKind)
    }

    /// One site's hops.
    struct Accumulator {
        var lane: InputTurnHopRecorder.Lane
        var site: String
        var frame: InputTurnHopRecorder.Frame?
        var stack: [InputTurnHopRecorder.Frame]
        var count = 0
        var turns: UInt8 = 0
        var origins: [UInt8: Int] = [:]
        var priorities: Set<UInt8> = []
        var callouts: Set<InputTurnHopRecorder.CalloutKind> = []
        var swiftJobs = false
        var totalNanos: UInt64 = 0
        var maxNanos: UInt64 = 0

        mutating func add(_ record: HopRecord) {
            count += 1
            turns |= record.turn.rawValue
            origins[record.origin, default: 0] += 1
            switch record.lane {
            case .swift:
                priorities.insert(record.priority)
            case .nonswift:
                callouts.insert(record.callout)
                // An unsampled main-queue or source stretch can hold Swift jobs; a sampled one says.
                swiftJobs = swiftJobs || (record.site == 0 ? record.callout != .timer : record.swiftJob)
            }
            totalNanos &+= record.nanos
            maxNanos = max(maxNanos, record.nanos)
        }

        var row: InputTurnHopRecorder.Row {
            let origin = Dictionary(origins.map { (Self.originName($0.key, lane: lane), $0.value) }, uniquingKeysWith: +)
            let timed = lane == .nonswift
            return InputTurnHopRecorder.Row(
                site: site, lane: lane, count: count, kinds: InputTurnHopRecorder.InputTurn(rawValue: turns).names,
                origin: origin, priorities: priorities.sorted().map { Int($0) },
                callouts: timed ? InputTurnHopRecorder.CalloutKind.allCases.filter { callouts.contains($0) }.map(\.name) : nil,
                includesSwiftJobs: timed ? swiftJobs : nil,
                totalMilliseconds: timed ? Double(totalNanos) / 1e6 : nil, maxMilliseconds: timed ? Double(maxNanos) / 1e6 : nil,
                frame: frame, stack: stack)
        }

        private static func originName(_ raw: UInt8, lane: InputTurnHopRecorder.Lane) -> String {
            switch lane {
            case .swift: InputTurnHopRecorder.Origin(rawValue: raw)?.name ?? "?"
            case .nonswift: InputTurnHopRecorder.RunLoopModeName(rawValue: raw)?.name ?? "?"
            }
        }
    }

    /// One window's sites.
    struct Window {
        var sites: [Key: Accumulator] = [:]
        var recorded: UInt64 = 0
        var overflow: UInt64 = 0

        /// Counts `record` at `key`; a new site starts from `new()`.
        mutating func add(_ record: HopRecord, key: Key, new: () -> Accumulator) {
            recorded &+= 1
            if sites[key] == nil {
                guard sites.count < InputTurnHopRecorder.siteLimit else {
                    overflow &+= 1
                    return
                }
                sites[key] = new()
            }
            sites[key]?.add(record)
        }
    }

    mutating func add(_ record: HopRecord) {
        // Between records only: a record's frames stay cached while its site is named.
        if resolved.count >= Self.resolvedLimit { resolved.removeAll(keepingCapacity: true) }
        let frames = record.stack.map { resolve($0) }
        let calloutSite = record.lane == .nonswift && record.site != 0 ? resolve(record.site) : nil
        let (site, siteFrame) = key(of: record, frames: frames, calloutSite: calloutSite)
        let new = { Self.accumulator(record, key: site, siteFrame: siteFrame, frames: frames) }
        sinceLaunch.add(record, key: site, new: new)
        sinceReset.add(record, key: site, new: new)
    }

    mutating func reset(dropped: UInt64) {
        sinceReset = Window()
        droppedAtReset = dropped
    }

    func snapshot(sinceLaunch launch: Bool, dropped: UInt64, pending: Int) -> InputTurnHopRecorder.Snapshot {
        let window = launch ? sinceLaunch : sinceReset
        let rows = window.sites.values.map(\.row).sorted { ($0.count, $1.site) > ($1.count, $0.site) }
        let sinceResetDropped = dropped >= droppedAtReset ? dropped - droppedAtReset : 0
        return InputTurnHopRecorder.Snapshot(sinceLaunch: launch, recorded: window.recorded,
                                               dropped: launch ? dropped : sinceResetDropped,
                                               sitesOverflow: window.overflow, pending: pending, rows: rows)
    }

    // MARK: Resolution

    /// The record's site and the site's frame: the first Swift frame past the runtime, or a sampled
    /// callout's resolved site.
    private func key(of record: HopRecord, frames: [ImageOffsetResolver.Resolved?],
                     calloutSite: ImageOffsetResolver.Resolved?) -> (Key, ImageOffsetResolver.Resolved?) {
        guard record.lane == .swift else {
            return calloutSite == nil ? (.callout(record.callout), nil) : (.calloutFrame(record.site), calloutSite)
        }
        let stack = record.stack
        guard !stack.isEmpty else { return (.noStack, nil) }
        guard let index = HopFrameResolver.siteIndex(frames.map { HopFrameResolver.kind($0, entry: entry) }) else { return (.truncated, nil) }
        return frames[index] == nil ? (.unresolved(stack[index]), nil) : (.frame(stack[index]), frames[index])
    }

    private mutating func resolve(_ address: UInt) -> ImageOffsetResolver.Resolved? {
        if let cached = resolved[address] { return cached }
        let frame = resolver.resolve(address)
        resolved[address] = .some(frame)
        return frame
    }

    /// A new site's accumulator: its name, frame and the first hop's stack, from the record's own
    /// resolved `frames` and `siteFrame`.
    private static func accumulator(_ record: HopRecord, key: Key, siteFrame: ImageOffsetResolver.Resolved?,
                                    frames: [ImageOffsetResolver.Resolved?]) -> Accumulator {
        let named = zip(record.stack, frames).map { address, resolved in
            resolved.map(frame) ?? InputTurnHopRecorder.Frame(image: "?", imageUUID: nil, offset: UInt64(address), nearestSymbol: nil)
        }
        let lane = record.lane
        switch key {
        case let .frame(address), let .calloutFrame(address):
            let site = siteFrame.map(frame)
            let name = site.map { "\($0.image)+0x\(String($0.offset, radix: 16))" } ?? "0x\(String(address, radix: 16))"
            return Accumulator(lane: lane, site: name, frame: site, stack: named)
        case let .unresolved(address):
            return Accumulator(lane: lane, site: "0x\(String(address, radix: 16))", frame: nil, stack: named)
        case .truncated:
            return Accumulator(lane: lane, site: "truncated", frame: nil, stack: named)
        case .noStack:
            return Accumulator(lane: lane, site: "?", frame: nil, stack: [])
        case let .callout(kind):
            return Accumulator(lane: lane, site: kind.site, frame: nil, stack: [])
        }
    }

    private static func frame(_ resolved: ImageOffsetResolver.Resolved) -> InputTurnHopRecorder.Frame {
        InputTurnHopRecorder.Frame(image: resolved.image.name, imageUUID: resolved.image.uuid?.uuidString, offset: UInt64(resolved.offset),
                                     nearestSymbol: resolved.nearestSymbol)
    }
}
#endif
