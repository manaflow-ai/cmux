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
/// the page has the keyboard instead, they are its keys (``LinkHintPendingKeys``).
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

/// What a link-hint session does with the keys typed after the `f` that started it, until its page answers (review of
/// #32537: every key reaches the page once and in order, or is a hint key; none is lost, and no key-up goes before its
/// key-down). Every key typed while the page answers is held, letters or not.
public nonisolated struct LinkHintPendingKeys<Key> {
    /// A held key as the session reads it.
    public enum Kind: Equatable, Sendable { case letter(String), backspace, escape, other }

    /// The keys for the page, and what the session does, once the page answered (``resolve(_:targets:editing:)``).
    public struct Resolution {
        public var page: [Key]
        public var outcome: LinkHintSession.Outcome
        /// The page has nothing to label.
        public var noLinks: Bool
    }

    private enum Entry {
        case down(Key, Kind, code: UInt16)
        case up(Key, code: UInt16)
        var key: Key { switch self { case .down(let key, _, _), .up(let key, _): key } }
    }

    private var entries: [Entry] = []
    /// Key codes whose key-down is held without its key-up.
    private var downs: Set<UInt16> = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Holds a key-down typed while the page answers.
    public mutating func hold(_ key: Key, kind: Kind, code: UInt16) {
        entries.append(.down(key, kind, code: code))
        downs.insert(code)
    }

    /// Holds a key-up whose key-down is held, so the page never gets an up before its down. False: not this session's.
    public mutating func holdUp(_ key: Key, code: UInt16) -> Bool {
        guard downs.remove(code) != nil else { return false }
        entries.append(.up(key, code: code))
        return true
    }

    /// The session ended before its page answered (a click, the keyboard left the page, the page call failed or took
    /// past its bound): nothing decided the keys, so every one goes to the page, in order.
    public mutating func releaseAll() -> [Key] {
        defer { (entries, downs) = ([], []) }
        return entries.map(\.key)
    }

    /// The page said no text field has the keyboard, before its labels come: the held keys run through `session` as typed
    /// now (review 6597001821), so later keys are handled live and nothing waits for the targets. Escape ends it and is its
    /// own; a key that is no hint key ends it, and it and every key after it are the page's.
    public mutating func resolveNoField(_ session: inout LinkHintSession) -> (page: [Key], ended: Bool) {
        defer { (entries, downs) = ([], []) }
        var ended = false, page: [Key] = [], pageDowns: Set<UInt16> = []
        for entry in entries {
            switch entry {
            case .up(let key, let code): if pageDowns.remove(code) != nil { page.append(key) }
            case .down(let key, let kind, let code):
                switch (ended, kind) {
                case (true, _), (false, .other):
                    ended = true
                    page.append(key)
                    pageDowns.insert(code)
                case (false, .escape): ended = true
                case (false, .letter(let letter)): _ = session.type(letter)
                case (false, .backspace): _ = session.type(nil)
                }
            }
        }
        return (page, ended)
    }

    /// The page answered. `editing` (a text field has the keyboard): every held key is the page's, in order. Otherwise
    /// they run through `session` as typed once its labels show: hint letters and Backspace narrow and pick; a pick,
    /// Escape or a key that is no hint key ends it, and that key (not Escape) and every key after it are the page's.
    /// With nothing to label, the hint letters before such a key are the session's.
    public mutating func resolve(_ session: inout LinkHintSession, targets: [LinkHintTarget], editing: Bool) -> Resolution {
        guard !editing else { return Resolution(page: releaseAll(), outcome: .passThrough, noLinks: false) }
        defer { (entries, downs) = ([], []) }
        var outcome = session.show(targets)
        let noLinks = outcome == .cancel
        var ended = false, page: [Key] = [], pageDowns: Set<UInt16> = []
        for entry in entries {
            guard case .down(let key, let kind, let code) = entry else {
                if case .up(let key, let code) = entry, pageDowns.remove(code) != nil { page.append(key) }
                continue
            }
            switch (ended, kind) {
            case (true, _), (false, .other):
                if !ended { (outcome, ended) = (.cancel, true) }
                page.append(key)
                pageDowns.insert(code)
            case (false, .escape): (outcome, ended) = (.cancel, true)
            case (false, _) where noLinks: continue // a hint letter or Backspace, with nothing to label
            case (false, .letter(let letter)): outcome = session.type(letter)
            case (false, .backspace): outcome = session.type(nil)
            }
            if case .pick = outcome { ended = true }
        }
        return Resolution(page: page, outcome: outcome, noLinks: noLinks)
    }
}

/// Key-downs the app already dispatched (review of #32537). Chromium sends a key the page left unhandled through the app
/// again (the same event); such a key the page already had is never a link-hint session's. It runs for every key-down of
/// the process, so it allocates nothing (KeyRouterBench: 0 allocations per plain key): a fixed ring of plain values.
public nonisolated struct LinkHintSeenKeys {
    /// A key-down's identity: its own time and key code (a HID event's time is nanoseconds since boot, so two identical
    /// keys in one display refresh differ); a synthetic key (time 0) is known by its object only.
    private struct Entry: Equatable {
        var time: TimeInterval
        var code: UInt16
        var object: ObjectIdentifier?
    }

    private var ring = ContiguousArray(repeating: Entry(time: -1, code: 0, object: nil), count: 32)
    private var next = 0

    public init() {}

    /// Notes the key-down `object` with its event `time` and key `code`: whether the app dispatched it before.
    public mutating func note(_ object: AnyObject, time: TimeInterval, code: UInt16) -> Bool {
        let entry = Entry(time: time, code: code, object: time == 0 ? ObjectIdentifier(object) : nil)
        if ring.contains(entry) { return true }
        ring[next] = entry
        next = next == ring.count - 1 ? 0 : next + 1
        return false
    }
}

/// The keys link hints sent back to the page (``LinkHintPendingKeys``): each goes on to the page untouched once, never
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
