public import CmuxNextInput
public import CmuxNextWakeups

/// `debug.input` action `late_keys`: the key-downs whose dispatch started more than 100 ms after their OS event time
/// (``KeyArrivalLedger``), newest last, each split into the main thread's wait (`generated -> arrived_main`) and a cmux
/// path's hold (`arrived_main -> dispatch_start`), with the path that held it, how many times `sendEvent` had it, the
/// responder chain and how new its terminal was (first-seconds-evidence.md step 1). Rows since the last `reset`, or
/// every row the ledger keeps with `since_launch`. Class names and numbers only: no user text.
///
/// `holds` is each hold path's stage since launch (``HeldKeyReplay``): every key it sent again,
/// late or not, with how long it held them.
public nonisolated struct LateKeysRecorder: DebugInputRecorder {
    private let ledger: KeyArrivalLedger
    private let heldKeys: HeldKeyReplay
    private let mainWork: MainWorkScheduler
    private let mark: Mark

    @MainActor
    final class Mark {
        var totalAtReset: UInt64 = 0

        nonisolated init() {}
    }

    /// - Parameters:
    ///   - ledger: The app's ledger (`InputLatencyDispatch.arrivals`), read on the main actor.
    ///   - heldKeys: The app's replay seam (`InputLatencyDispatch.heldKeys`), read on the main actor.
    ///   - mainWork: The app's main-thread scheduler, which runs each request's copy.
    public init(ledger: KeyArrivalLedger, heldKeys: HeldKeyReplay, mainWork: MainWorkScheduler) {
        self.ledger = ledger
        self.heldKeys = heldKeys
        self.mainWork = mainWork
        mark = Mark()
    }

    public var kind: DebugInputRecorderKind { .lateKeys }

    public func rows(sinceLaunch: Bool) async -> DebugInputLateKeys {
        await mainWork.apply(.automation, owner: "debug.input.late_keys") { [ledger, heldKeys, mark] in
            let fresh = ledger.lateTotal &- mark.totalAtReset
            let wanted = sinceLaunch ? Int.max : Int(clamping: fresh)
            return DebugInputLateKeys(total: ledger.lateTotal, keys: ledger.lateKeys(wanted).map(DebugInputLateKeys.Key.init),
                                      holds: heldKeys.stages.map { DebugInputLateKeys.Hold(path: $0.path, stage: $0.stage) })
        }
    }

    public func reset() async {
        await mainWork.apply(.automation, owner: "debug.input.late_keys") { [ledger, mark] in
            mark.totalAtReset = ledger.lateTotal
        }
    }
}

/// The JSON of `debug.input late_keys`.
public nonisolated struct DebugInputLateKeys: Encodable, Sendable, Equatable {
    public nonisolated struct Key: Encodable, Sendable, Equatable {
        public var keyCode: UInt16
        public var generatedNanos: UInt64
        /// OS event time to the first time the main thread had it.
        public var toArrivedMainMilliseconds: Double
        /// First arrival to the dispatch that ran it (a cmux path's hold).
        public var arrivedToDispatchMilliseconds: Double
        /// OS event time to the dispatch that ran it.
        public var dispatchStartMilliseconds: Double
        public var deliveries: UInt8
        public var heldBy: String
        public var target: String?
        public var responderChain: [String]
        /// From the hold to the dispatch, or nil when no path held it.
        public var heldToDispatchMilliseconds: Double?
        /// How old the terminal (or other view that knows its age) in the responder chain was at the dispatch.
        public var responderAgeMilliseconds: Double?

        init(_ key: KeyArrivalLedger.LateKey) {
            keyCode = key.keyCode
            generatedNanos = key.generatedNanos
            let arrived = max(key.arrivedMainNanos, key.generatedNanos)
            toArrivedMainMilliseconds = Double(arrived - key.generatedNanos) / 1e6
            arrivedToDispatchMilliseconds = Double(key.dispatchStartNanos > arrived ? key.dispatchStartNanos - arrived : 0) / 1e6
            dispatchStartMilliseconds = Double(key.dispatchStartNanos - key.generatedNanos) / 1e6
            deliveries = key.deliveries
            heldBy = String(describing: key.heldBy)
            target = key.target
            responderChain = key.responderChain
            heldToDispatchMilliseconds = key.heldNanos > 0 && key.dispatchStartNanos >= key.heldNanos
                ? Double(key.dispatchStartNanos - key.heldNanos) / 1e6 : nil
            responderAgeMilliseconds = key.responderAgeNanos.map { Double($0) / 1e6 }
        }

        private enum CodingKeys: String, CodingKey {
            case keyCode = "key_code"
            case generatedNanos = "generated_ns"
            case toArrivedMainMilliseconds = "to_arrived_main_ms"
            case arrivedToDispatchMilliseconds = "arrived_to_dispatch_ms"
            case dispatchStartMilliseconds = "dispatch_start_ms"
            case deliveries
            case heldBy = "held_by"
            case target
            case responderChain = "responder_chain"
            case heldToDispatchMilliseconds = "held_to_dispatch_ms"
            case responderAgeMilliseconds = "responder_age_ms"
        }
    }

    /// One hold path's stage since launch (``HeldKeyReplay/Stage``).
    public nonisolated struct Hold: Encodable, Sendable, Equatable {
        public var heldBy: String
        /// Keys the path held and sent again.
        public var count: UInt64
        /// Of those, keys held longer than the 50 ms limit.
        public var overLimit: UInt64
        public var maxMilliseconds: Double
        public var meanMilliseconds: Double
        /// Upper bound of each bucket in milliseconds (`null`: no bound) and its keys.
        public var buckets: [Bucket]

        public nonisolated struct Bucket: Encodable, Sendable, Equatable {
            public var upToMilliseconds: UInt64?
            public var keys: UInt64

            private enum CodingKeys: String, CodingKey {
                case upToMilliseconds = "up_to_ms"
                case keys
            }
        }

        init(path: KeyArrivalLedger.HoldPath, stage: HeldKeyReplay.Stage) {
            heldBy = String(describing: path)
            count = stage.count
            overLimit = stage.overLimit
            maxMilliseconds = Double(stage.maxNanos) / 1e6
            meanMilliseconds = stage.count > 0 ? Double(stage.totalNanos) / Double(stage.count) / 1e6 : 0
            let bounds = HeldKeyReplay.bucketBoundsMilliseconds
            buckets = stage.buckets.enumerated().map { Bucket(upToMilliseconds: $0.offset < bounds.count ? bounds[$0.offset] : nil, keys: $0.element) }
        }

        private enum CodingKeys: String, CodingKey {
            case heldBy = "held_by"
            case count
            case overLimit = "over_limit"
            case maxMilliseconds = "max_ms"
            case meanMilliseconds = "mean_ms"
            case buckets
        }
    }

    /// Late keys logged since launch.
    public var total: UInt64
    /// Oldest first.
    public var keys: [Key]
    /// Each path that held a key since launch, with its holds.
    public var holds: [Hold]
}
