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

    enum CodingKeys: String, CodingKey { case x, y, left, top, href }

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
/// the labels arrive are kept and checked when they do.
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
    public mutating func show(_ targets: [LinkHintTarget]) -> Outcome {
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
