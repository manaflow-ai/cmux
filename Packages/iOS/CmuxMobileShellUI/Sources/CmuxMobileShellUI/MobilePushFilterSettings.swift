import CMUXMobileCore
import Foundation
import Observation

/// User-authored push mute rules, persisted to an injected ``UserDefaults``
/// and mirrored to the server per device token.
///
/// Patterned on ``MobileDisplaySettings``: constructed once at the app
/// composition root and injected into the SwiftUI environment (no singleton).
/// Every mutation persists the full ``MobilePushFilterRules`` document under
/// ``documentKey`` AND fires `onRulesChanged` with that document, so the
/// composition root can forward it to the push registration sync without this
/// store importing networking. Local foreground filtering reads ``rules``
/// directly, so behavior is consistent even before the server sync lands.
@MainActor
@Observable
public final class MobilePushFilterSettings {
    // UserDefaults is Apple-documented thread-safe; the synchronous read in
    // `init` and the write-through on mutation are safe nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    /// Versioned persistence key for the filters document JSON.
    public static let documentKey = "dev.cmux.mobile.pushFilters.v1"
    /// Sync seam, fired on the main actor after every persisted mutation.
    @ObservationIgnored
    private let onRulesChanged: @MainActor (MobilePushFilterRules) -> Void

    /// The current mute rules, in authored order (at most
    /// ``MobilePushFilterRules/maxRuleCount``).
    public private(set) var rules: [MobilePushFilterRule]

    /// Creates the store, seeding ``rules`` from the persisted document.
    /// - Parameters:
    ///   - defaults: The store backing persistence. Tests pass a scoped
    ///     `UserDefaults(suiteName:)`.
    ///   - onRulesChanged: Called after every persisted mutation with the full
    ///     current document (the composition root forwards it to the server
    ///     sync). Defaults to a no-op for previews and tests.
    public init(
        defaults: UserDefaults,
        onRulesChanged: @escaping @MainActor (MobilePushFilterRules) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.onRulesChanged = onRulesChanged
        if let data = defaults.data(forKey: Self.documentKey),
           let document = try? JSONDecoder().decode(
               MobilePushFilterRules.self,
               from: data
           ) {
            self.rules = document.rules
        } else {
            self.rules = []
        }
    }

    /// The current rules as the versioned wire document.
    public var document: MobilePushFilterRules {
        MobilePushFilterRules(rules: rules)
    }

    /// The rule muting `groupId` (scoped to `macDeviceId` when both carry
    /// one), when it exists. A rule without a Mac scope matches any Mac.
    public func groupRule(
        groupId: String,
        macDeviceId: String?
    ) -> MobilePushFilterRule? {
        rules.first { rule in
            guard let ruleGroupId = rule.groupId,
                  ruleGroupId.caseInsensitiveCompare(groupId) == .orderedSame
            else { return false }
            return Self.macScopeMatches(rule.macDeviceId, macDeviceId)
        }
    }

    /// Mutes a workspace group, snapshotting its id, display name, and owning
    /// Mac. Re-enables an existing rule for the same group instead of
    /// duplicating it.
    /// - Returns: Whether a rule now mutes the group.
    @discardableResult
    public func addGroupRule(
        groupId: String,
        groupName: String?,
        macDeviceId: String?
    ) -> Bool {
        if let existing = groupRule(groupId: groupId, macDeviceId: macDeviceId) {
            setEnabled(true, id: existing.id)
            return true
        }
        guard rules.count < MobilePushFilterRules.maxRuleCount,
              let rule = MobilePushFilterRule.validated(
                  groupId: groupId,
                  groupName: groupName,
                  macDeviceId: macDeviceId
              )
        else { return false }
        rules.append(rule)
        commit()
        return true
    }

    /// Removes the mute rule for a workspace group (the toggle-off path).
    public func removeGroupRule(groupId: String, macDeviceId: String?) {
        let remaining = rules.filter { rule in
            guard let ruleGroupId = rule.groupId,
                  ruleGroupId.caseInsensitiveCompare(groupId) == .orderedSame,
                  Self.macScopeMatches(rule.macDeviceId, macDeviceId)
            else { return true }
            return false
        }
        guard remaining.count != rules.count else { return }
        rules = remaining
        commit()
    }

    /// Adds a title mute pattern after validating that it compiles as a
    /// case-insensitive regular expression and respects the wire limits.
    /// - Returns: `nil` when the rule was added, otherwise why it was refused.
    @discardableResult
    public func addTitleRule(pattern: String) -> MobilePushFilterPatternRejection? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.count <= MobilePushFilterRule.maxStringLength else {
            return .tooLong
        }
        guard (try? NSRegularExpression(
            pattern: trimmed,
            options: [.caseInsensitive]
        )) != nil else { return .invalidPattern }
        guard !rules.contains(where: { rule in
            rule.titlePattern?.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return .duplicate }
        guard rules.count < MobilePushFilterRules.maxRuleCount else {
            return .limitReached
        }
        guard let rule = MobilePushFilterRule.validated(titlePattern: trimmed)
        else { return .invalidPattern }
        rules.append(rule)
        commit()
        return nil
    }

    /// Enables or disables one rule without touching its criteria.
    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }),
              rules[index].enabled != enabled
        else { return }
        rules[index].enabled = enabled
        commit()
    }

    /// Deletes one rule (swipe-to-delete path).
    public func remove(id: UUID) {
        let remaining = rules.filter { $0.id != id }
        guard remaining.count != rules.count else { return }
        rules = remaining
        commit()
    }

    private func commit() {
        let document = MobilePushFilterRules(rules: rules)
        if let data = try? document.encodedData() {
            defaults.set(data, forKey: Self.documentKey)
        }
        onRulesChanged(document)
    }

    /// A rule authored without a Mac scope applies to any Mac; a scoped rule
    /// only matches the same Mac (case-insensitive).
    private static func macScopeMatches(
        _ ruleMacDeviceId: String?,
        _ macDeviceId: String?
    ) -> Bool {
        guard let ruleMacDeviceId else { return true }
        guard let macDeviceId else { return false }
        return ruleMacDeviceId.caseInsensitiveCompare(macDeviceId) == .orderedSame
    }
}
