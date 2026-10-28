public import CmuxNextSignposts
import CmuxNextCompat

// Every build: a new terminal's once-per-create stages, `create.tab` instants keyed by the create's intent id
// (``NewTerminalTrace``, p09-observability task 043).
extension NewTerminalTrace {
    /// The intent id a view's first attach carries, taken once (``take()``): a reattach after it, or a retry of
    /// a failed first attach, is no create stage.
    public final class FirstAttach: Sendable {
        private let intent: Atomic<UInt64>

        /// - Parameter intent: The `create.tab` intent id the view's terminal was made for; 0: none (a restore).
        public init(intent: UInt64) {
            self.intent = Atomic(intent)
        }

        /// The intent id on the first call, 0 after it.
        public func take() -> UInt64 { intent.exchange(0, ordering: .relaxed) }
    }

    /// A terminal view's tie to the `create.tab` interval of the new tab it shows: its main-actor stages (the
    /// session, a final grid) are that create's while the interval is open. Weak: it ends with the interval.
    @MainActor
    public struct CreateStages {
        private weak var create: CreateTabInterval?
        private let trace: NewTerminalTrace

        /// - Parameters:
        ///   - create: The new tab's interval; nil: the view shows no create (a restore).
        ///   - trace: The recorder the stages go to (tests pass their own).
        public init(_ create: CreateTabInterval? = nil, trace: NewTerminalTrace = .shared) {
            self.create = create
            self.trace = trace
        }

        /// Writes stage `mark` while the interval is open (``NewTerminalTrace/event(_:of:value:)``).
        public func event(_ mark: Mark, value: UInt64 = 0) {
            trace.event(mark, of: create, value: value)
        }
    }

    /// Writes stage `mark` of `create` while it is a new terminal's open interval (nil, ended or another kind:
    /// nothing).
    @MainActor
    public func event(_ mark: Mark, of create: CreateTabInterval?, value: UInt64 = 0) {
        guard let create, create.isOpen, create.kind == .terminal else { return }
        event(mark, intent: create.intentID, value: value)
    }

    /// Runs `send`, the daemon request that creates the terminal of `create`, between that create's `request_sent`
    /// and `reply` stages (nil or ended: no stage); `surface` reads the reply's daemon surface, the reply's value.
    @MainActor
    public func request<Reply>(of create: CreateTabInterval?, surface: (Reply) -> UInt64,
                               _ send: () async throws -> Reply) async throws -> Reply {
        event(.requestSent, of: create)
        let reply = try await send()
        event(.reply, of: create, value: surface(reply))
        return reply
    }

    /// Attach stage `mark` on daemon surface `surface`: the instant when the attach is a create's first
    /// (`intent`, from ``FirstAttach``; 0 otherwise) and, while a `debug.new_terminal_trace` run is armed, its
    /// mark when `surface` is the bound terminal's.
    public func attachEvent(_ mark: Mark, surface: UInt64, intent: UInt64) {
        event(mark, intent: intent, value: surface)
        #if DEBUG || CMUX_BENCH_HOOKS
        self.mark(mark, surface: surface)
        #endif
    }

    /// A stage instant's `arg0`: the stage in bits 0-7, the low 56 bits of `value` above it.
    public static func stageArg(_ mark: Mark, value: UInt64) -> UInt64 {
        mark.traceCode | value << 8
    }

    /// A grid as a stage value: the columns in bits 24-47 and the rows in bits 0-23, each clamped to 24 bits.
    public static func gridValue(columns: Int, rows: Int) -> UInt64 {
        let limit = (1 << 24) - 1
        return UInt64(min(max(columns, 0), limit)) << 24 | UInt64(min(max(rows, 0), limit))
    }
}
