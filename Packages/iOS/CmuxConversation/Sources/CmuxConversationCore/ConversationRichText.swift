import Foundation

/// iMessage text formatting (Bold, Italic, Underline, Strikethrough).
public struct ConversationTextStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = ConversationTextStyle(rawValue: 1 << 0)
    public static let italic = ConversationTextStyle(rawValue: 1 << 1)
    public static let underline = ConversationTextStyle(rawValue: 1 << 2)
    public static let strikethrough = ConversationTextStyle(rawValue: 1 << 3)

    /// Canonical order, matching the formatting palette and the wire.
    public static let all: [(style: ConversationTextStyle, name: String)] = [
        (.bold, "bold"), (.italic, "italic"), (.underline, "underline"), (.strikethrough, "strikethrough"),
    ]

    public var wireNames: [String] { Self.all.filter { contains($0.style) }.map(\.name) }

    public init(wireNames: [String]) {
        self = Self.all.reduce(into: []) { result, entry in
            if wireNames.contains(entry.name) { result.insert(entry.style) }
        }
    }
}

/// iMessage animated text effects, in Messages' palette order.
public enum ConversationTextEffect: String, Sendable, Hashable, CaseIterable {
    case big
    case small
    case shake
    case nod
    case explode
    case ripple
    case bloom
    case jitter
}

/// One formatted span of a message's text. `location` and `length` count
/// UTF-16 code units, so they are `NSRange`s into the text.
public struct ConversationTextRun: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public var style: ConversationTextStyle
    public var effect: ConversationTextEffect?

    public init(location: Int, length: Int, style: ConversationTextStyle = [], effect: ConversationTextEffect? = nil) {
        self.location = location
        self.length = length
        self.style = style
        self.effect = effect
    }

    public var range: NSRange { NSRange(location: location, length: length) }
    public var isPlain: Bool { style.isEmpty && effect == nil }
}

extension NSAttributedString.Key {
    /// `ConversationTextStyle.rawValue` as an `Int`. Composers and bubbles keep
    /// formatting in these semantic keys and derive fonts from them.
    public static let conversationTextStyle = NSAttributedString.Key("cmuxConversationTextStyle")
    /// `ConversationTextEffect.rawValue`.
    public static let conversationTextEffect = NSAttributedString.Key("cmuxConversationTextEffect")
}

/// Pure helpers between run lists and attributed strings. All ranges are UTF-16.
public enum ConversationRichText {
    /// Clips runs to the text, drops plain or empty ones, resolves overlaps
    /// (later runs win), sorts them and merges adjacent equal spans.
    public static func normalized(_ runs: [ConversationTextRun], utf16Count: Int) -> [ConversationTextRun] {
        guard utf16Count > 0, !runs.isEmpty else { return [] }
        var styles = [ConversationTextStyle](repeating: [], count: utf16Count)
        var effects = [ConversationTextEffect?](repeating: nil, count: utf16Count)
        var touched = false
        for run in runs {
            let lower = max(0, run.location)
            let upper = min(utf16Count, run.location + max(0, run.length))
            guard lower < upper else { continue }
            for index in lower..<upper {
                styles[index] = run.style
                effects[index] = run.effect
            }
            touched = true
        }
        guard touched else { return [] }
        return compress(styles: styles, effects: effects)
    }

    private static func compress(styles: [ConversationTextStyle], effects: [ConversationTextEffect?]) -> [ConversationTextRun] {
        var result: [ConversationTextRun] = []
        var start = 0
        for index in 1...styles.count {
            if index < styles.count, styles[index] == styles[start], effects[index] == effects[start] { continue }
            let run = ConversationTextRun(location: start, length: index - start, style: styles[start], effect: effects[start])
            if !run.isPlain { result.append(run) }
            start = index
        }
        return result
    }

    /// Carries formatting through a plain-text edit: characters in the
    /// unchanged prefix and suffix keep their style and effect, the replaced
    /// middle is plain (what a text view does when you retype that span).
    public static func carried(_ runs: [ConversationTextRun], from oldText: String, to newText: String) -> [ConversationTextRun] {
        let old = Array(oldText.utf16)
        let new = Array(newText.utf16)
        guard !runs.isEmpty, !new.isEmpty else { return [] }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let delta = new.count - old.count
        var carried: [ConversationTextRun] = []
        for run in normalized(runs, utf16Count: old.count) {
            let head = NSIntersectionRange(run.range, NSRange(location: 0, length: prefix))
            if head.length > 0 { carried.append(ConversationTextRun(location: head.location, length: head.length, style: run.style, effect: run.effect)) }
            let tail = NSIntersectionRange(run.range, NSRange(location: old.count - suffix, length: suffix))
            if tail.length > 0 { carried.append(ConversationTextRun(location: tail.location + delta, length: tail.length, style: run.style, effect: run.effect)) }
        }
        return normalized(carried, utf16Count: new.count)
    }

    /// Trims surrounding whitespace the way a send does and shifts the runs.
    public static func trimmed(_ text: String, runs: [ConversationTextRun]) -> (text: String, runs: [ConversationTextRun]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runs.isEmpty, !trimmed.isEmpty, let range = text.range(of: trimmed) else { return (trimmed, []) }
        let offset = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let shifted = runs.map { run -> ConversationTextRun in
            var run = run
            run.location -= offset
            return run
        }
        return (trimmed, normalized(shifted, utf16Count: trimmed.utf16.count))
    }

    /// Reads the semantic keys back into runs.
    public static func runs(in string: NSAttributedString) -> [ConversationTextRun] {
        var runs: [ConversationTextRun] = []
        let whole = NSRange(location: 0, length: string.length)
        string.enumerateAttributes(in: whole) { attributes, range, _ in
            let style = ConversationTextStyle(rawValue: attributes[.conversationTextStyle] as? Int ?? 0)
            let effect = (attributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
            runs.append(ConversationTextRun(location: range.location, length: range.length, style: style, effect: effect))
        }
        return normalized(runs, utf16Count: string.length)
    }

    /// Writes runs into the semantic keys (replacing any present).
    public static func apply(_ runs: [ConversationTextRun], to string: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: string.length)
        string.removeAttribute(.conversationTextStyle, range: whole)
        string.removeAttribute(.conversationTextEffect, range: whole)
        for run in normalized(runs, utf16Count: string.length) {
            if !run.style.isEmpty { string.addAttribute(.conversationTextStyle, value: run.style.rawValue, range: run.range) }
            if let effect = run.effect { string.addAttribute(.conversationTextEffect, value: effect.rawValue, range: run.range) }
        }
    }

    public static func style(at index: Int, in string: NSAttributedString) -> ConversationTextStyle {
        guard index >= 0, index < string.length else { return [] }
        return ConversationTextStyle(rawValue: string.attribute(.conversationTextStyle, at: index, effectiveRange: nil) as? Int ?? 0)
    }

    public static func effect(at index: Int, in string: NSAttributedString) -> ConversationTextEffect? {
        guard index >= 0, index < string.length else { return nil }
        return (string.attribute(.conversationTextEffect, at: index, effectiveRange: nil) as? String).flatMap(ConversationTextEffect.init(rawValue:))
    }

    /// True when every unit of `range` carries `style`.
    public static func range(_ range: NSRange, of string: NSAttributedString, hasAll style: ConversationTextStyle) -> Bool {
        guard range.length > 0 else { return false }
        for index in range.location..<NSMaxRange(range) where !self.style(at: index, in: string).contains(style) {
            return false
        }
        return true
    }

    /// The effect shared by every unit of `range`, if any.
    public static func commonEffect(in range: NSRange, of string: NSAttributedString) -> ConversationTextEffect? {
        guard range.length > 0, let first = effect(at: range.location, in: string) else { return nil }
        for index in range.location..<NSMaxRange(range) where effect(at: index, in: string) != first {
            return nil
        }
        return first
    }

    /// Toggles `style` on `range` like a text editor's Bold button: added to
    /// every unit unless all units already carry it. Returns whether it is on.
    @discardableResult
    public static func toggle(_ style: ConversationTextStyle, in range: NSRange, of string: NSMutableAttributedString) -> Bool {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        guard range.length > 0 else { return false }
        let enable = !self.range(range, of: string, hasAll: style)
        for index in range.location..<NSMaxRange(range) {
            var current = self.style(at: index, in: string)
            if enable { current.insert(style) } else { current.remove(style) }
            let unit = NSRange(location: index, length: 1)
            if current.isEmpty {
                string.removeAttribute(.conversationTextStyle, range: unit)
            } else {
                string.addAttribute(.conversationTextStyle, value: current.rawValue, range: unit)
            }
        }
        return enable
    }

    /// Applies `effect` to `range`; choosing the effect the range already has
    /// removes it (Messages' palette toggles the same way). Returns the result.
    @discardableResult
    public static func toggle(_ effect: ConversationTextEffect, in range: NSRange, of string: NSMutableAttributedString) -> ConversationTextEffect? {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        guard range.length > 0 else { return nil }
        if commonEffect(in: range, of: string) == effect {
            string.removeAttribute(.conversationTextEffect, range: range)
            return nil
        }
        string.addAttribute(.conversationTextEffect, value: effect.rawValue, range: range)
        return effect
    }
}
