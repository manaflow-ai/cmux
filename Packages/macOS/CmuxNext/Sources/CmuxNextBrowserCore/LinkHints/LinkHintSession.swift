public import Foundation

/// One clickable element on screen, as the hint script reports it: where to
/// click (viewport CSS pixels), where its label goes, and its link.
public nonisolated struct LinkHintTarget: Hashable, Sendable, Decodable {
    public var x: Double
    public var y: Double
    public var left: Double
    public var top: Double
    /// http(s) link target, nil for buttons, fields and other elements.
    public var href: URL?

    public init(x: Double, y: Double, left: Double, top: Double, href: URL? = nil) {
        self.x = x
        self.y = y
        self.left = left
        self.top = top
        self.href = href
    }

    package enum CodingKeys: String, CodingKey { case x, y, left, top, href }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        left = try c.decode(Double.self, forKey: .left)
        top = try c.decode(Double.self, forKey: .top)
        href = try c.decodeIfPresent(String.self, forKey: .href).flatMap(URL.init(string:)).flatMap { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
    }
}

/// The keys of one link-hint session (`f`, or `F` to open in a new split):
/// letters narrow the labels until one is typed in full; a letter no label
/// continues with is ignored; Backspace undoes a letter. Keys typed before
/// the labels arrive are kept and checked when they do; when a text field of
/// the page has the keyboard instead, they are its keys (``LinkHintHeldKeys``).
public nonisolated struct LinkHintSession: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Click the element in the page.
        case follow
        /// Open the link in a new browser split (links only).
        case newSplit
    }

    public enum Outcome: Equatable, Sendable {
        /// Show only labels that start with `prefix`.
        case narrow(prefix: String)
        /// The label is complete: act on this target.
        case pick(LinkHintTarget)
        /// Nothing to label: the session ends.
        case cancel
        /// A text field of the page has the keyboard: the session ends, and the letters typed meanwhile are the
        /// field's, in order.
        case passThrough
    }

    public let mode: Mode
    public private(set) var typed = ""
    /// Labels and targets once the page answered; nil while collecting.
    public private(set) var hints: [(label: String, target: LinkHintTarget)]?

    public init(mode: Mode) {
        self.mode = mode
    }

    /// The labels for `targets` (links only in `.newSplit`); `.cancel` when
    /// there is nothing to label, else what the keys typed so far mean.
    /// `editing`: a text field of the page has the keyboard (the page's own answer).
    public mutating func show(_ targets: [LinkHintTarget], editing: Bool = false) -> Outcome {
        guard !editing else { return .passThrough }
        let usable = mode == .newSplit ? targets.filter { $0.href != nil } : targets
        let labels = LinkHintSession.labels(count: usable.count)
        hints = Array(zip(labels, usable)).map { (label: $0.0, target: $0.1) }
        guard !usable.isEmpty else { return .cancel }
        // Letters typed early that fit no label are dropped from the end.
        while !typed.isEmpty, !fits(typed) { typed.removeLast() }
        return resolve()
    }

    /// A letter (lowercase), or nil for Backspace.
    public mutating func type(_ letter: String?) -> Outcome {
        if let letter {
            let next = typed + letter.lowercased()
            if hints == nil || fits(next) { typed = next }
        } else if !typed.isEmpty {
            typed.removeLast()
        }
        return resolve()
    }

    private func fits(_ prefix: String) -> Bool {
        hints?.contains { $0.label.hasPrefix(prefix) } ?? true
    }

    private func resolve() -> Outcome {
        if let hit = hints?.first(where: { $0.label == typed }) { return .pick(hit.target) }
        return .narrow(prefix: typed)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.typed == rhs.typed
            && lhs.hints?.map(\.label) == rhs.hints?.map(\.label) && lhs.hints?.map(\.target) == rhs.hints?.map(\.target)
    }
}

/// The keys a link-hint session took before the page answered (``LinkHintSession/show(_:editing:)``), in order. Once
/// it answered they are the text field's when one has the keyboard (``LinkHintSession/Outcome/passThrough``): each
/// goes to the page once, in the order typed; otherwise they were hint keys and none goes to the page.
public nonisolated struct LinkHintHeldKeys<Key> {
    public private(set) var keys: [Key] = []
    /// When the session started (the event clock, seconds since boot).
    private let startedAt: TimeInterval

    public init(startedAt: TimeInterval) { self.startedAt = startedAt }

    /// Where a key goes: the page on its normal path, or this session.
    public enum Route: Equatable, Sendable { case page, session }

    /// Where a key typed at `typedAt` (its event's own timestamp, not when it is dispatched) goes. One typed before the
    /// session started is no hint key and is never held: it goes on to the page on its normal path, once. That covers a
    /// key still queued when the session started (it reaches the page now, before the keys typed after it) and a key
    /// Chromium sent back after the page had it (the same event; it stays in Chromium's redispatch, as with no session).
    /// A key without a time (a synthetic event, 0) is the session's.
    public func route(typedAt: TimeInterval) -> Route { typedAt > 0 && typedAt < startedAt ? .page : .session }

    /// `key` is the session's (``route(typedAt:)``): held until the page answers.
    public mutating func hold(_ key: Key) { keys.append(key) }

    /// The held keys the page gets now, after `outcome`: all of them, once, for ``LinkHintSession/Outcome/passThrough``.
    public mutating func release(after outcome: LinkHintSession.Outcome) -> [Key] {
        defer { keys = [] }
        return outcome == .passThrough ? keys : []
    }
}

/// The keys link hints sent back to the page (``LinkHintHeldKeys``): each goes on to the page untouched once, never
/// held or taken by a session again (a key sent again and taken again looped without end, v5 of #32537).
public nonisolated struct LinkHintReplays<Key: AnyObject> {
    /// Held, so a key's identity is never another key's (a freed event's address reused).
    private var pending: [Key] = []

    public init() {}

    /// `keys` are being sent back now; a send-back is synchronous, so an earlier batch has had its turn.
    public mutating func mark(_ keys: [Key]) { pending = keys }

    /// Whether `key` is one sent back to the page; true once.
    public mutating func isReplay(_ key: Key) -> Bool {
        guard let index = pending.firstIndex(where: { $0 === key }) else { return false }
        pending.remove(at: index)
        return true
    }
}
