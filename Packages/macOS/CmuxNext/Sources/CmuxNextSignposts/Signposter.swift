public import os

/// Always-on signpost intervals for one ``SignpostCategory``, the same in Debug and Release.
///
/// An interval costs one enabled check when nothing records and a few hundred nanoseconds when a
/// recorder (`log stream --signpost`, Instruments) is attached. Place intervals per user event or
/// per frame, never per pane per frame. Nothing leaves the Mac.
///
/// ```swift
/// let state = Signposter.action.begin(.actionPerform, "id=\(id)")
/// defer { Signposter.action.end(.actionPerform, state) }
/// ```
public nonisolated struct Signposter: Sendable {
    /// The category this signposter emits.
    public let category: SignpostCategory
    private let signposter: OSSignposter

    /// A signposter for `category` under ``SignpostCategory/subsystem``.
    public init(category: SignpostCategory) {
        self.category = category
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

    /// Whether a recorder may receive this category's signposts (skip work that only feeds them).
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
        return SignpostInterval(state: signposter.beginInterval(name.staticName, id: id, "\(message, privacy: .public)"))
    }

    /// Ends an interval begun with ``begin(_:_:)`` under the same name.
    public func end(_ name: SignpostName, _ interval: SignpostInterval) {
        signposter.endInterval(name.staticName, interval.state)
    }

    /// Runs `body` inside an interval named `name`.
    ///
    /// - Returns: What `body` returns.
    public func interval<T>(_ name: SignpostName, _ message: String = "", _ body: () throws -> T) rethrows -> T {
        let interval = begin(name, message)
        defer { end(name, interval) }
        return try body()
    }

    /// Records a point event named `name`.
    public func event(_ name: SignpostName, _ message: String = "") {
        signposter.emitEvent(name.staticName, "\(message, privacy: .public)")
    }
}
