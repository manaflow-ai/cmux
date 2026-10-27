import CMUXAgentLaunch
import Foundation
import Testing

@Suite("SessionPriorityMatrix")
struct SessionPriorityMatrixTests {
    private func decode(_ json: String) throws -> SessionPriorityMatrix {
        try SessionPriorityMatrix(json: Data(json.utf8))
    }

    @Test func shippedDefaultMatchesTheSpecTable() {
        let m = SessionPriorityMatrix.shippedDefault
        #expect(m.target(tier: .urgent, difficulty: .easy).effort == .medium)
        #expect(m.target(tier: .urgent, difficulty: .normal).effort == .high)
        #expect(m.target(tier: .urgent, difficulty: .hard).effort == .xhigh)
        #expect(m.target(tier: .slow, difficulty: .easy).effort == .low)
        #expect(m.target(tier: .slow, difficulty: .normal).effort == .medium)
        #expect(m.target(tier: .slow, difficulty: .hard).effort == .medium)
        for tier in SessionPriorityTier.allCases {
            for difficulty in ClaudeSessionDifficulty.allCases {
                #expect(m.target(tier: tier, difficulty: difficulty).model == nil)
            }
        }
    }

    @Test func decodesACellWithAModel() throws {
        let m = try decode(#"{"urgent": {"hard": {"effort": "max", "model": "opus"}}}"#)
        let t = m.target(tier: .urgent, difficulty: .hard)
        #expect(t.effort == .max)
        #expect(t.model == "opus")
    }

    @Test func missingCellKeepsTheShippedDefault() throws {
        let m = try decode(#"{"urgent": {"hard": {"effort": "max"}}}"#)
        #expect(m.target(tier: .urgent, difficulty: .hard).effort == .max)
        #expect(m.target(tier: .slow, difficulty: .easy).effort == .low)
        #expect(m.target(tier: .urgent, difficulty: .easy).effort == .medium)
    }

    @Test func emptyCellIsNotAdjusted() throws {
        let m = try decode(#"{"slow": {"easy": {}}}"#)
        #expect(m.target(tier: .slow, difficulty: .easy).isEmpty)
        for tier in SessionPriorityTier.allCases {
            for difficulty in ClaudeSessionDifficulty.allCases where !(tier == .slow && difficulty == .easy) {
                #expect(m.target(tier: tier, difficulty: difficulty)
                    == SessionPriorityMatrix.shippedDefault.target(tier: tier, difficulty: difficulty))
            }
        }
    }

    @Test func writtenCellReplacesTheWholeCell() throws {
        let m = try decode(#"{"urgent": {"hard": {"model": "opus"}}}"#)
        let t = m.target(tier: .urgent, difficulty: .hard)
        #expect(t.effort == nil)
        #expect(t.model == "opus")
        #expect(m.target(tier: .urgent, difficulty: .normal).effort == .high)
    }

    @Test func emptyObjectEqualsShippedDefault() throws {
        #expect(try decode("{}") == .shippedDefault)
    }

    @Test func rejectsUnknownEffort() {
        #expect(throws: SessionPriorityMatrixError.invalidEffort("ultra")) {
            try decode(#"{"urgent": {"easy": {"effort": "ultra"}}}"#)
        }
    }

    @Test func rejectsUnknownKey() {
        #expect(throws: SessionPriorityMatrixError.unknownKey(path: "urgent.medium")) {
            try decode(#"{"urgent": {"medium": {"effort": "low"}}}"#)
        }
        #expect(throws: SessionPriorityMatrixError.unknownKey(path: "slow.easy.foo")) {
            try decode(#"{"slow": {"easy": {"foo": 1}}}"#)
        }
        #expect(throws: SessionPriorityMatrixError.unknownKey(path: "later")) {
            try decode(#"{"later": {}}"#)
        }
    }

    @Test func rejectsNonObjects() {
        #expect(throws: SessionPriorityMatrixError.notAnObject(path: "")) { try decode("[]") }
        #expect(throws: SessionPriorityMatrixError.notAnObject(path: "urgent")) {
            try decode(#"{"urgent": 1}"#)
        }
    }

    @Test func rejectsModelWithShellCharacters() {
        #expect(throws: SessionPriorityMatrixError.invalidModel("opus; rm -rf")) {
            try decode(#"{"urgent": {"easy": {"model": "opus; rm -rf"}}}"#)
        }
    }

    @Test func canonicalStringRoundTrips() throws {
        let m = try decode(#"{"slow": {"hard": {"model": "opus", "effort": "low"}, "easy": {}}, "urgent": {"easy": {"effort": "high"}}}"#)
        let canonical = m.canonicalJSONString()
        #expect(canonical == #"{"slow":{"easy":{},"hard":{"effort":"low","model":"opus"},"normal":{"effort":"medium"}},"urgent":{"easy":{"effort":"high"},"hard":{"effort":"xhigh"},"normal":{"effort":"high"}}}"#)
        #expect(try decode(canonical) == m)
        #expect(try decode(SessionPriorityMatrix.shippedDefault.canonicalJSONString()) == .shippedDefault)
    }

    @Test func fromStoredStringFallsBackToDefault() {
        #expect(SessionPriorityMatrix.fromStoredString("") == .shippedDefault)
        #expect(SessionPriorityMatrix.fromStoredString("{") == .shippedDefault)
    }
}
