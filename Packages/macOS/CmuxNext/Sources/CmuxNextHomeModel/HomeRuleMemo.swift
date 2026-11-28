import CmuxNextCompat
import Foundation
import os

/// A pure rules call's answers by their whole input (thread p1795759419, cmux#59531's class): a
/// row builder or a view's body asks `HomeRules.call` per row per draw, each a JSON encode, an FFI
/// call and a decode on the main thread. The rule is pure, so an equal input is the same answer and
/// nothing is ever invalidated; past `limit` inputs it starts over, which only bounds a long session.
///
/// ```swift
/// static let badges = HomeRuleMemo<String?, String?>()
/// badges.value(harness) { try? HomeRules.call("chief_settings.backendBadge", ...) }
/// ```
public nonisolated final class HomeRuleMemo<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let answers = OSAllocatedUnfairLock<[Key: Value]>(initialState: [:])
    private let limit: Int

    public init(limit: Int = 256) { self.limit = limit }

    /// `key`'s answer: the remembered one, else `rule`'s (asked outside the lock), then remembered.
    public func value(_ key: Key, _ rule: () -> Value) -> Value {
        if let known = answers.withLock({ $0[key] }) { return known }
        let answer = rule()
        answers.withLock { answers in
            if answers.count >= limit { answers.removeAll(keepingCapacity: true) }
            answers[key] = answer
        }
        return answer
    }
}

/// A memo key for a rule whose request carries localized strings: the input and the app language's
/// bundle, so a language switch while the app runs asks the rule again (``Bundle/localizedModule``).
public nonisolated struct HomeRuleLanguageKey<Input: Hashable & Sendable>: Hashable, Sendable {
    public let input: Input
    public let language: String

    public init(_ input: Input) {
        self.input = input
        language = Bundle.localizedModule.bundlePath
    }
}
