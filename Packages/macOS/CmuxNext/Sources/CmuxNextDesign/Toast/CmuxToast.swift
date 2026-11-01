import Foundation

/// One toast (R96): a short message at the bottom of a window, with at
/// most one action (Undo, Reopen or a custom one). `CmuxToastCenter` shows
/// it and ends it after `duration`.
public nonisolated struct CmuxToast: Equatable, Sendable {
    public nonisolated struct Action: Equatable, Sendable {
        public var title: String
        /// Cmd-Z runs it while the toast shows and the focused responder
        /// has nothing of its own to undo.
        public var isUndo: Bool

        public init(title: String, isUndo: Bool = false) {
            self.title = title
            self.isUndo = isUndo
        }

        public static func undo(_ title: String = CmuxToastStrings.undo) -> Action { Action(title: title, isUndo: true) }
        public static func reopen(_ title: String = CmuxToastStrings.reopen) -> Action { Action(title: title) }
    }

    /// A new toast with the same id replaces the one showing.
    public var id: String
    public var message: String
    /// More about the message, shown in a tooltip when the pointer is on the
    /// message (and read by VoiceOver as the toast's help); nil: none.
    /// Keeps the toast short when the details are long (which subagents
    /// could not be stopped, and why).
    public var detail: String?
    public var action: Action?
    public var duration: Duration

    /// A duration that never times out: the toast stays until its action or close button
    /// (the server-update prompt, which asks for a decision).
    public static let untilClosed: Duration = .zero

    public init(id: String, message: String, detail: String? = nil, action: Action? = nil, duration: Duration = .seconds(6)) {
        self.id = id
        self.message = message
        self.detail = detail?.isEmpty == false ? detail : nil
        self.action = action
        self.duration = duration
    }
}

/// Why a toast ended.
public nonisolated enum CmuxToastDismissReason: String, Equatable, Sendable {
    /// Its time ran out.
    case timeout
    /// The close button, `dismiss()`, or its window closed.
    case closed
    /// A newer toast took its place (same id, or a fourth toast).
    case replaced
    /// Its action ran.
    case action
}

/// Which toasts a window shows: at most `limit`, oldest first. Pure.
public nonisolated struct CmuxToastStack: Equatable, Sendable {
    public static let limit = 3
    public private(set) var serials: [Int] = []
    private var ids: [Int: String] = [:]
    private var undo: Set<Int> = []

    public init() {}

    /// Adds toast `serial`; returns the serials it replaces (same id, then
    /// the oldest over the limit).
    public mutating func push(serial: Int, id: String, undo isUndo: Bool) -> [Int] {
        var removed = serials.filter { ids[$0] == id }
        for old in removed { remove(old) }
        serials.append(serial)
        ids[serial] = id
        if isUndo { undo.insert(serial) }
        while serials.count > Self.limit {
            let oldest = serials[0]
            remove(oldest)
            removed.append(oldest)
        }
        return removed
    }

    public mutating func remove(_ serial: Int) {
        serials.removeAll { $0 == serial }
        ids[serial] = nil
        undo.remove(serial)
    }

    /// The newest toast whose action is an undo.
    public var newestUndo: Int? { serials.last { undo.contains($0) } }
}
