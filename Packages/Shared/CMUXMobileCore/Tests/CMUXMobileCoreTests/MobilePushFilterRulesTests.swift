import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobilePushFilterRulesTests {
    private func rule(
        id: UUID = UUID(),
        enabled: Bool = true,
        groupId: String? = nil,
        groupName: String? = nil,
        macDeviceId: String? = nil,
        titlePattern: String? = nil
    ) throws -> MobilePushFilterRule {
        try #require(MobilePushFilterRule.validated(
            id: id,
            enabled: enabled,
            groupId: groupId,
            groupName: groupName,
            macDeviceId: macDeviceId,
            titlePattern: titlePattern
        ))
    }

    @Test func encodesExactWireShape() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let document = MobilePushFilterRules(rules: [
            try rule(
                id: id,
                groupId: "group-1",
                groupName: "Backend",
                macDeviceId: "MAC-1",
                titlePattern: "fail"
            ),
        ])
        let json = try #require(
            try JSONSerialization.jsonObject(with: document.encodedData())
                as? [String: Any]
        )
        #expect(Set(json.keys) == ["version", "rules"])
        #expect(json["version"] as? Int == 1)
        let rules = try #require(json["rules"] as? [[String: Any]])
        let encoded = try #require(rules.first)
        #expect(Set(encoded.keys) == [
            "id", "enabled", "groupId", "groupName", "macDeviceId", "titlePattern",
        ])
        #expect(encoded["id"] as? String == id.uuidString)
        #expect(encoded["enabled"] as? Bool == true)
        #expect(encoded["groupId"] as? String == "group-1")
        #expect(encoded["groupName"] as? String == "Backend")
        #expect(encoded["macDeviceId"] as? String == "MAC-1")
        #expect(encoded["titlePattern"] as? String == "fail")
    }

    @Test func titleOnlyRuleOmitsAbsentKeys() throws {
        let document = MobilePushFilterRules(rules: [
            try rule(titlePattern: "^build"),
        ])
        let json = try #require(
            try JSONSerialization.jsonObject(with: document.encodedData())
                as? [String: Any]
        )
        let encoded = try #require((json["rules"] as? [[String: Any]])?.first)
        #expect(Set(encoded.keys) == ["id", "enabled", "titlePattern"])
    }

    @Test func roundTripPreservesRules() throws {
        let document = MobilePushFilterRules(rules: [
            try rule(groupId: "g1", groupName: "One", macDeviceId: "m1"),
            try rule(enabled: false, titlePattern: "deploy"),
        ])
        let decoded = try JSONDecoder().decode(
            MobilePushFilterRules.self,
            from: document.encodedData()
        )
        #expect(decoded == document)
    }

    @Test func decodeDropsInvalidRulesWithoutFailingTheDocument() throws {
        let oversized = String(repeating: "a", count: 201)
        let json = """
        {"version": 1, "rules": [
            {"id": "11111111-2222-3333-4444-555555555555", "enabled": true, "groupId": "keep-1"},
            {"id": "21111111-2222-3333-4444-555555555555", "enabled": true, "macDeviceId": "mac-only"},
            {"id": "31111111-2222-3333-4444-555555555555", "enabled": true, "titlePattern": "\(oversized)"},
            "not-an-object",
            null,
            42,
            [true],
            {"id": "41111111-2222-3333-4444-555555555555", "enabled": false, "titlePattern": "keep-2"}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            MobilePushFilterRules.self,
            from: Data(json.utf8)
        )
        #expect(decoded.rules.count == 2)
        #expect(decoded.rules.first?.groupId == "keep-1")
        #expect(decoded.rules.last?.titlePattern == "keep-2")
        #expect(decoded.rules.last?.enabled == false)
    }

    @Test func initTruncatesPastTheRuleLimit() throws {
        let rules = try (0..<70).map { try rule(titlePattern: "pattern-\($0)") }
        let document = MobilePushFilterRules(rules: rules)
        #expect(document.rules.count == MobilePushFilterRules.maxRuleCount)
        #expect(document.rules.last?.titlePattern == "pattern-63")
    }

    @Test func decodeCapsAtTheRuleLimit() throws {
        let elements = (0..<70).map {
            #"{"id": "\#(UUID().uuidString)", "enabled": true, "titlePattern": "p\#($0)"}"#
        }.joined(separator: ",")
        let decoded = try JSONDecoder().decode(
            MobilePushFilterRules.self,
            from: Data(#"{"version": 1, "rules": [\#(elements)]}"#.utf8)
        )
        #expect(decoded.rules.count == MobilePushFilterRules.maxRuleCount)
    }

    @Test func validatedRefusesRulesWithoutCriteria() {
        #expect(MobilePushFilterRule.validated() == nil)
        // macDeviceId alone is a scope, not a criterion.
        #expect(MobilePushFilterRule.validated(macDeviceId: "mac-1") == nil)
        // Whitespace-only strings count as absent.
        #expect(MobilePushFilterRule.validated(groupId: "  ", groupName: "\n") == nil)
    }

    @Test func validatedEnforcesTheStringLimit() {
        let maxed = String(repeating: "x", count: MobilePushFilterRule.maxStringLength)
        #expect(MobilePushFilterRule.validated(titlePattern: maxed) != nil)
        #expect(MobilePushFilterRule.validated(titlePattern: maxed + "x") == nil)
        #expect(MobilePushFilterRule.validated(
            groupId: "g",
            macDeviceId: maxed + "x"
        ) == nil)
    }
}
