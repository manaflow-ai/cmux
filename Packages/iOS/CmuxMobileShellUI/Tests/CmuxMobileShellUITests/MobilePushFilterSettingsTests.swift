import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobilePushFilterSettingsTests {
    /// Builds a scoped defaults suite so tests never touch `.standard`.
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "MobilePushFilterSettingsTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func startsEmptyWithoutAWrite() throws {
        let defaults = try makeDefaults("empty")
        let settings = MobilePushFilterSettings(defaults: defaults)
        #expect(settings.rules.isEmpty)
        #expect(defaults.object(forKey: MobilePushFilterSettings.documentKey) == nil)
    }

    @Test func titleRulePersistsAcrossInstances() throws {
        let defaults = try makeDefaults("titlePersists")
        let settings = MobilePushFilterSettings(defaults: defaults)
        #expect(settings.addTitleRule(pattern: "fail(ed|ure)") == nil)

        let reloaded = MobilePushFilterSettings(defaults: defaults)
        #expect(reloaded.rules.count == 1)
        #expect(reloaded.rules.first?.titlePattern == "fail(ed|ure)")
        #expect(reloaded.rules.first?.enabled == true)
    }

    @Test func persistedDocumentUsesTheWireSchema() throws {
        let defaults = try makeDefaults("wireSchema")
        let settings = MobilePushFilterSettings(defaults: defaults)
        settings.addGroupRule(groupId: "g1", groupName: "One", macDeviceId: "m1")

        let data = try #require(
            defaults.data(forKey: MobilePushFilterSettings.documentKey)
        )
        let document = try JSONDecoder().decode(MobilePushFilterRules.self, from: data)
        #expect(document.version == 1)
        #expect(document.rules.first?.groupId == "g1")
        #expect(document.rules.first?.groupName == "One")
        #expect(document.rules.first?.macDeviceId == "m1")
    }

    @Test func everyMutationFiresOnRulesChanged() throws {
        let defaults = try makeDefaults("callback")
        var observed: [MobilePushFilterRules] = []
        let settings = MobilePushFilterSettings(defaults: defaults) { document in
            observed.append(document)
        }

        settings.addGroupRule(groupId: "g1", groupName: "One", macDeviceId: "m1")
        #expect(settings.addTitleRule(pattern: "error") == nil)
        let titleRule = try #require(
            settings.rules.first { $0.titlePattern == "error" }
        )
        settings.setEnabled(false, id: titleRule.id)
        settings.remove(id: titleRule.id)
        settings.removeGroupRule(groupId: "g1", macDeviceId: "m1")

        #expect(observed.count == 5)
        #expect(observed.last?.rules.isEmpty == true)
        // Each callback carries the FULL document at that point.
        #expect(observed[1].rules.count == 2)
    }

    @Test func groupToggleAddRemoveRoundTrips() throws {
        let defaults = try makeDefaults("groupRoundTrip")
        let settings = MobilePushFilterSettings(defaults: defaults)

        #expect(settings.addGroupRule(
            groupId: "group-1",
            groupName: "Backend",
            macDeviceId: "MAC-1"
        ))
        let rule = try #require(
            settings.groupRule(groupId: "GROUP-1", macDeviceId: "mac-1")
        )
        #expect(rule.groupName == "Backend")
        #expect(rule.enabled)

        // Re-adding the same group re-enables instead of duplicating.
        settings.setEnabled(false, id: rule.id)
        #expect(settings.addGroupRule(
            groupId: "group-1",
            groupName: "Backend",
            macDeviceId: "MAC-1"
        ))
        #expect(settings.rules.count == 1)
        #expect(settings.rules.first?.enabled == true)

        settings.removeGroupRule(groupId: "group-1", macDeviceId: "MAC-1")
        #expect(settings.groupRule(groupId: "group-1", macDeviceId: "MAC-1") == nil)
        #expect(MobilePushFilterSettings(defaults: defaults).rules.isEmpty)
    }

    @Test func groupRuleForAnotherMacIsSeparate() throws {
        let defaults = try makeDefaults("groupMacScope")
        let settings = MobilePushFilterSettings(defaults: defaults)
        settings.addGroupRule(groupId: "group-1", groupName: "One", macDeviceId: "MAC-1")
        settings.addGroupRule(groupId: "group-1", groupName: "One", macDeviceId: "MAC-2")
        #expect(settings.rules.count == 2)
        settings.removeGroupRule(groupId: "group-1", macDeviceId: "MAC-2")
        #expect(settings.rules.count == 1)
        #expect(settings.rules.first?.macDeviceId == "MAC-1")
    }

    @Test func patternValidationRejectsBadInput() throws {
        let defaults = try makeDefaults("patternValidation")
        let settings = MobilePushFilterSettings(defaults: defaults)

        #expect(settings.addTitleRule(pattern: "   ") == .empty)
        #expect(settings.addTitleRule(pattern: "([") == .invalidPattern)
        #expect(settings.addTitleRule(
            pattern: String(repeating: "a", count: 201)
        ) == .tooLong)

        #expect(settings.addTitleRule(pattern: "deploy") == nil)
        #expect(settings.addTitleRule(pattern: "DEPLOY") == .duplicate)
        #expect(settings.rules.count == 1)
    }

    @Test func ruleCountIsCapped() throws {
        let defaults = try makeDefaults("limit")
        let settings = MobilePushFilterSettings(defaults: defaults)
        for index in 0..<MobilePushFilterRules.maxRuleCount {
            #expect(settings.addTitleRule(pattern: "pattern-\(index)") == nil)
        }
        #expect(settings.addTitleRule(pattern: "one-too-many") == .limitReached)
        #expect(!settings.addGroupRule(
            groupId: "group-1",
            groupName: "One",
            macDeviceId: nil
        ))
        #expect(settings.rules.count == MobilePushFilterRules.maxRuleCount)
    }

    @Test func corruptPersistedDocumentReadsAsEmpty() throws {
        let defaults = try makeDefaults("corrupt")
        defaults.set(Data("not json".utf8), forKey: MobilePushFilterSettings.documentKey)
        #expect(MobilePushFilterSettings(defaults: defaults).rules.isEmpty)
    }
}
