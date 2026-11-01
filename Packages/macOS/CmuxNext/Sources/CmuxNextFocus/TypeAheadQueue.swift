/// Keys typed into a page surface before its document can take them (spec
/// app-screens.md section 3, R59): one surface's printable text, in order,
/// at most 256 characters and 2 s old. The key router owns one and drops it
/// on a chord or a focus move. The rules are `cmux-focus-core`'s
/// `TypeAheadQueue`; this value mirrors its state and calls it synchronously.
public nonisolated struct TypeAheadQueue: Equatable {
    public init() {}
    private struct Wire: Codable, Equatable {
        var surface: String?
        var text = ""
        var startedNs: Int64?
    }

    private var wire = Wire()
    /// Deletes typed after the queued text was taken for the page and before it landed there: they
    /// belong to that text, so they go to the page after it (``takeDeletes()``), never dropped.
    public private(set) var deletesAfterTaken = 0
    /// Times go to the rule as nanoseconds after this instant: a day before
    /// its first use, so every instant this process passes is after it.
    private static let origin = ContinuousClock.now - .seconds(86_400)

    public var surface: String? { wire.surface }
    public var text: String { wire.text }

    /// Whether text waits for `surface`.
    public func pending(for surface: String) -> Bool {
        run(.pending(surface: surface))?.pending ?? false
    }

    /// Appends `characters` for `surface`; text for another surface, or text
    /// older than 2 s, is dropped first. Characters past 256 are dropped.
    public mutating func append(_ characters: String, surface: String, now: ContinuousClock.Instant) {
        apply(.append(characters: characters, surface: surface, nowNs: Self.nanoseconds(now)))
    }

    /// Delete while the page loads removes the last queued character. With nothing queued while
    /// taken text is still on its way to the page (`delivering`), it counts for that text instead.
    public mutating func deleteBackward(surface: String, delivering: Bool = false) {
        guard pending(for: surface) || !delivering else {
            deletesAfterTaken += 1
            return
        }
        apply(.deleteBackward(surface: surface))
    }

    /// The Deletes counted for text that was on its way to the page, once.
    public mutating func takeDeletes() -> Int {
        defer { deletesAfterTaken = 0 }
        return deletesAfterTaken
    }

    public var pendingDeletes: Int { deletesAfterTaken }

    /// Drops text that has not been taken for delivery while keeping Deletes already typed for the
    /// in-flight text. A chord or focus move may cancel the waiting text, but it must not reorder a
    /// Delete behind that text or lose it before `flushTypeAhead` takes it.
    public mutating func dropPendingText() {
        wire = Wire()
    }

    /// The queued text for `surface`, once; nil when none waits or it is
    /// older than 2 s (then it is dropped).
    public mutating func take(surface: String, now: ContinuousClock.Instant) -> String? {
        apply(.take(surface: surface, nowNs: Self.nanoseconds(now)))?.text
    }

    public mutating func drop() {
        wire = Wire()
        deletesAfterTaken = 0
    }

    private enum Op: Encodable {
        case append(characters: String, surface: String, nowNs: Int64)
        case deleteBackward(surface: String)
        case take(surface: String, nowNs: Int64)
        case pending(surface: String)
    }

    private struct Response: Decodable {
        var queue: Wire
        var text: String?
        var pending: Bool
    }

    private func run(_ op: Op) -> Response? {
        struct Request: Encodable {
            var queue: Wire
            var op: Op
        }
        let response = FocusReducer.call("focus_type_ahead", Request(queue: wire, op: op), as: Response.self)
        assert(response != nil, "focus_type_ahead refused")
        return response
    }

    @discardableResult
    private mutating func apply(_ op: Op) -> Response? {
        guard let response = run(op) else { return nil }
        wire = response.queue
        return response
    }

    private static func nanoseconds(_ instant: ContinuousClock.Instant) -> Int64 {
        let elapsed = (instant - origin).components
        return elapsed.seconds &* 1_000_000_000 &+ elapsed.attoseconds / 1_000_000_000
    }
}
