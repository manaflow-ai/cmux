#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// The fold's tables of ``MainJobGateDiagnostics``: hops by site, since launch and since the last
/// reset, each at most ``MainJobGateDiagnostics/siteLimit`` sites. Only the fold (under the
/// recorder's lock, never on the main thread) touches it.
struct HopSites {
    /// The most resolved addresses cached; past it the cache starts over.
    static let resolvedLimit = 4096

    private var resolver = HopFrameResolver()
    private var resolved: [UInt: HopFrameResolver.Resolved?] = [:]
    private var sinceLaunch = Window()
    private var sinceReset = Window()
    private var droppedAtReset: UInt64 = 0

    /// A site: a Swift job's frame address, an unresolved Swift stack's innermost address, or a
    /// kind of non-Swift callout.
    enum Key: Hashable {
        case frame(UInt)
        case unresolved(UInt)
        case noStack
        case callout(MainJobGateDiagnostics.CalloutKind)
    }

    /// One site's hops.
    struct Accumulator {
        var lane: MainJobGateDiagnostics.Lane
        var site: String
        var frame: MainJobGateDiagnostics.Frame?
        var stack: [MainJobGateDiagnostics.Frame]
        var count = 0
        var turns: UInt8 = 0
        var origins: [UInt8: Int] = [:]
        var priorities: Set<UInt8> = []
        var totalNanos: UInt64 = 0
        var maxNanos: UInt64 = 0

        mutating func add(_ record: HopRecord) {
            count += 1
            turns |= record.turn.rawValue
            origins[record.origin, default: 0] += 1
            if record.lane == .swift { priorities.insert(record.priority) }
            totalNanos &+= record.nanos
            maxNanos = max(maxNanos, record.nanos)
        }

        var row: MainJobGateDiagnostics.Row {
            let origin = Dictionary(origins.map { (Self.originName($0.key, lane: lane), $0.value) }, uniquingKeysWith: +)
            let timed = lane == .nonswift
            return MainJobGateDiagnostics.Row(
                site: site, lane: lane, count: count, kinds: MainJobGateDiagnostics.InputTurn(rawValue: turns).names,
                origin: origin, priorities: priorities.sorted().map { Int($0) },
                totalMilliseconds: timed ? Double(totalNanos) / 1e6 : nil, maxMilliseconds: timed ? Double(maxNanos) / 1e6 : nil,
                frame: frame, stack: stack)
        }

        private static func originName(_ raw: UInt8, lane: MainJobGateDiagnostics.Lane) -> String {
            switch lane {
            case .swift: MainJobGateDiagnostics.Origin(rawValue: raw)?.name ?? "?"
            case .nonswift: MainJobGateDiagnostics.RunLoopModeName(rawValue: raw)?.name ?? "?"
            }
        }
    }

    /// One window's sites.
    struct Window {
        var sites: [Key: Accumulator] = [:]
        var recorded: UInt64 = 0
        var overflow: UInt64 = 0

        /// Counts `record` at `key`; a new site starts from `new` (nil: the site is known).
        mutating func add(_ record: HopRecord, key: Key, new: Accumulator?) {
            recorded &+= 1
            if sites[key] == nil {
                guard sites.count < MainJobGateDiagnostics.siteLimit, let new else {
                    overflow &+= 1
                    return
                }
                sites[key] = new
            }
            sites[key]?.add(record)
        }
    }

    mutating func add(_ record: HopRecord) {
        let site = key(of: record)
        let new = sinceLaunch.sites[site] == nil || sinceReset.sites[site] == nil ? accumulator(record, key: site) : nil
        sinceLaunch.add(record, key: site, new: new)
        sinceReset.add(record, key: site, new: new)
    }

    mutating func reset(dropped: UInt64) {
        sinceReset = Window()
        droppedAtReset = dropped
    }

    func snapshot(sinceLaunch launch: Bool, dropped: UInt64, pending: Int) -> MainJobGateDiagnostics.Snapshot {
        let window = launch ? sinceLaunch : sinceReset
        let rows = window.sites.values.map(\.row).sorted { ($0.count, $1.site) > ($1.count, $0.site) }
        return MainJobGateDiagnostics.Snapshot(sinceLaunch: launch, recorded: window.recorded,
                                               dropped: launch ? dropped : dropped &- droppedAtReset,
                                               sitesOverflow: window.overflow, pending: pending, rows: rows)
    }

    // MARK: Resolution

    private mutating func key(of record: HopRecord) -> Key {
        guard record.lane == .swift else { return .callout(record.callout) }
        let stack = record.stack
        guard let first = stack.first else { return .noStack }
        let frames = stack.map { resolve($0) }
        guard let index = HopFrameResolver.siteIndex(frames.map { $0?.image.isRuntime }), frames[index] != nil else {
            return .unresolved(first)
        }
        return .frame(stack[index])
    }

    private mutating func resolve(_ address: UInt) -> HopFrameResolver.Resolved? {
        if let cached = resolved[address] { return cached }
        if resolved.count >= Self.resolvedLimit { resolved.removeAll(keepingCapacity: true) }
        let frame = resolver.resolve(address)
        resolved[address] = .some(frame)
        return frame
    }

    /// A new site's accumulator: its name, frame and the first hop's stack (the addresses are
    /// resolved already: ``key(of:)`` ran first).
    private func accumulator(_ record: HopRecord, key: Key) -> Accumulator {
        let frames = record.stack.map { address in
            (resolved[address] ?? nil).map(Self.frame) ?? MainJobGateDiagnostics.Frame(image: "?", imageUUID: nil, offset: UInt64(address),
                                                                                     nearestSymbol: nil)
        }
        switch key {
        case let .frame(address):
            let frame = (resolved[address] ?? nil).map(Self.frame)
            let site = frame.map { "\($0.image)+0x\(String($0.offset, radix: 16))" } ?? "0x\(String(address, radix: 16))"
            return Accumulator(lane: .swift, site: site, frame: frame, stack: frames)
        case let .unresolved(address):
            return Accumulator(lane: .swift, site: "0x\(String(address, radix: 16))", frame: nil, stack: frames)
        case .noStack:
            return Accumulator(lane: .swift, site: "?", frame: nil, stack: [])
        case let .callout(kind):
            return Accumulator(lane: .nonswift, site: kind.site, frame: nil, stack: [])
        }
    }

    private static func frame(_ resolved: HopFrameResolver.Resolved) -> MainJobGateDiagnostics.Frame {
        MainJobGateDiagnostics.Frame(image: resolved.image.name, imageUUID: resolved.image.uuid, offset: UInt64(resolved.offset),
                                     nearestSymbol: resolved.nearestSymbol)
    }
}
#endif
