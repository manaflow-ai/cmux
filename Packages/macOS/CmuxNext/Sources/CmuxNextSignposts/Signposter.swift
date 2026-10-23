public import os

/// Always-on signpost intervals for one ``SignpostCategory``, the same in Debug and Release.
///
/// Signposts of a custom subsystem are enabled by default, so ``isEnabled`` is true in every
/// build and every interval is handed to the log system whether or not a recorder (`log stream
/// --signpost`, Instruments) is attached: about a microsecond per begin or end, and the message
/// text the caller builds. Prefer the typed messages (``ActionSignpostMessage``), whose fields the
/// log system formats only when something reads them, over a `String` built per call. Place
/// intervals per user event or per frame, never per pane per frame. Nothing leaves the Mac.
///
/// ```swift
/// let state = Signposter.action.begin(.actionPerform, "id=\(id)")
/// defer { Signposter.action.end(.actionPerform, state) }
/// ```
public nonisolated struct Signposter: Sendable {
    /// The category this signposter emits.
    public let category: SignpostCategory
    private let signposter: OSSignposter
    /// The MetricKit mirror this signposter repeats intervals to (the app's: ``SignpostMetricKitMirror/shared``).
    private let mirror: SignpostMetricKitMirror

    /// A signposter for `category` under ``SignpostCategory/subsystem``.
    public init(category: SignpostCategory) {
        self.init(category: category, mirror: .shared)
    }

    /// - Parameter mirror: The MetricKit mirror (tests pass their own, so they never switch the
    ///   process-wide one that other suites running in parallel read).
    init(category: SignpostCategory, mirror: SignpostMetricKitMirror) {
        self.category = category
        self.mirror = mirror
        signposter = OSSignposter(subsystem: SignpostCategory.subsystem, category: category.rawValue)
    }

    // The per-category handles below are declarations: OSSignposter is an immutable handle (like
    // `Logger`); the log system owns all state, so these are not singletons.
    /// ``SignpostCategory/action``.
    public static let action = Signposter(category: .action)
    /// ``SignpostCategory/motion``.
    public static let motion = Signposter(category: .motion)
    /// ``SignpostCategory/key``.
    public static let key = Signposter(category: .key)
    /// ``SignpostCategory/switch``.
    public static let `switch` = Signposter(category: .switch)
    /// ``SignpostCategory/create``.
    public static let create = Signposter(category: .create)
    /// ``SignpostCategory/cef``.
    public static let cef = Signposter(category: .cef)
    /// ``SignpostCategory/launch``.
    public static let launch = Signposter(category: .launch)
    /// ``SignpostCategory/stall``.
    public static let stall = Signposter(category: .stall)

    /// Whether the log system takes this category's signposts (true unless a logging profile
    /// turns the subsystem off; it does not mean a recorder is attached). Skip work that only
    /// feeds signposts when it is false.
    public var isEnabled: Bool { signposter.isEnabled }

    /// Begins an interval named `name` with a public message.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: Public text recorded with the begin (ids and kinds, never user content).
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: String = "") -> SignpostInterval {
        assert(name.category == category, "\(name) is not in category \(category)")
        let id = signposter.makeSignpostID()
        return SignpostInterval(state: signposter.beginInterval(name.staticName, id: id, "\(message, privacy: .public)"),
                                metricKitID: mirror.begin(name))
    }

    /// Begins an interval named `name` with an action's fields, formatted by the log system only
    /// when something reads them (`id=<id> origin=<origin> input_age_ms=<age, 2 decimals>`).
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - message: The action's id, origin and input age.
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, _ message: ActionSignpostMessage) -> SignpostInterval {
        assert(name.category == category, "\(name) is not in category \(category)")
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(
            name.staticName, id: id,
            "id=\(message.id, privacy: .public) origin=\(message.origin, privacy: .public) input_age_ms=\(message.inputAgeMilliseconds, format: .fixed(precision: 2), privacy: .public)"
        )
        return SignpostInterval(state: state, metricKitID: mirror.begin(name))
    }

    /// Begins an interval named `name` for one scheduled main-thread task (``SignpostName/stallMainTask``),
    /// with its class and owner formatted by the log system only when something reads them
    /// (`class=<class> owner=<owner>`): the scheduler opens one per task, so no `String` is built per call.
    ///
    /// - Parameters:
    ///   - name: A catalog name of this signposter's category.
    ///   - taskClass: The task's priority class name (`visible`, `automation`, ...).
    ///   - owner: The batch owner or control method that scheduled the task.
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func begin(_ name: SignpostName, taskClass: String, owner: String) -> SignpostInterval {
        assert(name.category == category, "\(name) is not in category \(category)")
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name.staticName, id: id,
                                             "class=\(taskClass, privacy: .public) owner=\(owner, privacy: .public)")
        return SignpostInterval(state: state, metricKitID: mirror.begin(name))
    }

    /// Ends an interval begun with ``begin(_:_:)`` under the same name.
    public func end(_ name: SignpostName, _ interval: SignpostInterval) {
        signposter.endInterval(name.staticName, interval.state)
        if let id = interval.metricKitID { mirror.end(name, id: id) }
    }

    /// Ends an interval that ``CommitBoundary`` closed: a ``CommitBoundary/Outcome/missed`` end
    /// carries the message `commit=missed`, so readers drop it instead of counting idle time. The
    /// MetricKit mirror ends only a committed interval: a missed one's begin stays unmatched, so
    /// MetricKit leaves it out of the histogram.
    public func end(_ name: SignpostName, _ interval: SignpostInterval, _ outcome: CommitBoundary.Outcome) {
        switch outcome {
        case .committed:
            signposter.endInterval(name.staticName, interval.state)
            if let id = interval.metricKitID { mirror.end(name, id: id) }
        case .missed:
            signposter.endInterval(name.staticName, interval.state, "commit=missed")
        }
    }

    /// Ends an interval whose synchronous work ran a nested run loop that waited for the person
    /// (an `NSMenu` pop-up, a modal panel): the end carries `loop=nested`, so readers keep it out
    /// of latency rows instead of counting the person's dwell time. Like a missed commit, it is not
    /// mirrored to MetricKit.
    public func endSpanningNestedLoop(_ name: SignpostName, _ interval: SignpostInterval) {
        signposter.endInterval(name.staticName, interval.state, "loop=nested")
    }

    /// Runs `body` inside an interval named `name`.
    ///
    /// - Returns: What `body` returns.
    public func interval<T>(_ name: SignpostName, _ message: String = "", _ body: () throws -> T) rethrows -> T {
        let interval = begin(name, message)
        defer { end(name, interval) }
        return try body()
    }

    /// Runs `body` inside an interval named `name` with an action's fields.
    ///
    /// - Returns: What `body` returns.
    public func interval<T>(_ name: SignpostName, _ message: ActionSignpostMessage, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name, message)
        defer { end(name, interval) }
        return try body()
    }

    /// Records a point event named `name`.
    public func event(_ name: SignpostName, _ message: String = "") {
        signposter.emitEvent(name.staticName, "\(message, privacy: .public)")
    }
}
