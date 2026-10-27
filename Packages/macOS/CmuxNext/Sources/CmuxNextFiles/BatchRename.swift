public import Foundation

/// Finder's Rename Items sheet (select several items, Rename…): one rule
/// applied to each name's stem, so extensions stay.
///
/// ```swift
/// let rename = BatchRename(rule: .format(base: "Trip", style: .index, position: .afterName, start: 1))
/// rename.plan(["b.jpg", "a.jpg"], taken: folderNames) // "Trip 1.jpg", "Trip 2.jpg"
/// ```
public struct BatchRename: Sendable, Equatable {
    /// What changes in each name.
    public enum Rule: Sendable, Equatable {
        /// Replace Text: every `find` in the stem becomes `with`.
        case replace(find: String, with: String, caseSensitive: Bool)
        /// Add Text: `text` before or after the stem.
        case add(text: String, position: Position)
        /// Format: the stem becomes `base` plus a number or the date.
        case format(base: String, style: FormatStyle, position: Position, start: Int)
    }

    /// Where added text or the number goes.
    public enum Position: Sendable, Equatable {
        /// Before the name.
        case beforeName
        /// After the name (before the extension).
        case afterName
    }

    /// Finder's Format choices.
    public enum FormatStyle: Sendable, Equatable {
        /// Name and Index: "Trip 1".
        case index
        /// Name and Counter: "Trip 00001".
        case counter
        /// Name and Date: "Trip 2026-10-19 at 10.15.32".
        case date
    }

    /// Why one new name cannot be used.
    public enum Problem: Sendable, Equatable {
        /// Empty, `/`, `..` or too long.
        case invalid
        /// Format's number for this item is past `Int.max`: the start number is too large for
        /// this many items. `to` is the old name, as no new name exists.
        case numberTooLarge
        /// Another item in this rename gets the same name.
        case duplicate
        /// An item not in this rename has the name.
        case exists
    }

    /// One item's old and new name.
    public struct Item: Sendable, Equatable {
        /// The name now.
        public let from: String
        /// The name after the rename.
        public let to: String
        /// Why `to` cannot be used; nil when it can.
        public let problem: Problem?
        /// Whether the name changes at all.
        public var changes: Bool { from != to }
    }

    /// The rule.
    public var rule: Rule
    private let now: Date
    private let calendar: Calendar

    /// Makes a rename. `now` and `calendar` feed Name and Date (seams for tests).
    public init(rule: Rule, now: Date = Date(), calendar: Calendar = .current) {
        self.rule = rule
        self.now = now
        self.calendar = calendar
    }

    /// The new name of each of `names`, in order (the order sets Index and Counter).
    /// `taken` is every name in the folder; names in `names` count as free.
    public func plan(_ names: [String], taken: Set<String>) -> [Item] {
        let namer = FileNamer()
        let leaving = Set(names)
        var seen: Set<String> = []
        return names.enumerated().map { offset, name in
            let renamed = newName(for: name, offset: offset)
            let to = renamed ?? name
            let problem: Problem?
            if renamed == nil {
                problem = .numberTooLarge
            } else if !namer.isValid(to) {
                problem = .invalid
            } else if seen.contains(to) {
                problem = .duplicate
            } else if to != name, taken.contains(to), !leaving.contains(to) {
                problem = .exists
            } else {
                problem = nil
            }
            seen.insert(to)
            return Item(from: name, to: to, problem: problem)
        }
    }

    /// Nil when the item's number does not fit in an `Int`.
    private func newName(for name: String, offset: Int) -> String? {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        switch rule {
        case .replace(let find, let with, let caseSensitive):
            guard !find.isEmpty else { return name }
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return stem.replacingOccurrences(of: find, with: with, options: options) + suffix
        case .add(let text, let position):
            return (position == .beforeName ? text + stem : stem + text) + suffix
        case .format(let base, let style, let position, let start):
            let (number, overflow) = start.addingReportingOverflow(offset)
            let mark: String
            switch style {
            case .index, .counter:
                guard !overflow else { return nil }
                mark = style == .index ? String(number) : String(format: "%05ld", number)
            case .date: mark = dateText()
            }
            return (position == .beforeName ? "\(mark) \(base)" : "\(base) \(mark)") + suffix
        }
    }

    private func dateText() -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let two = { (value: Int?) in String(format: "%02d", value ?? 0) }
        return "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day)) at \(two(parts.hour)).\(two(parts.minute)).\(two(parts.second))"
    }
}
