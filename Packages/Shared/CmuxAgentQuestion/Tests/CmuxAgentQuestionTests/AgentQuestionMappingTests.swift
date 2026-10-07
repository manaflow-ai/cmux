import CmuxAgentQuestion
import Foundation
import Testing

@Suite struct AgentQuestionMappingTests {
    @Test func everyFixtureMapsToItsExpectedQuestion() throws {
        let names = AgentQuestionFixture.names
        #expect(names.count >= 11)
        for name in names {
            let fixture = try AgentQuestionFixture(name: name)
            let mapped = try #require(fixture.mapped(), "\(name) did not map")
            #expect(mapped == fixture.question, "\(name)")
        }
    }

    @Test func expectedQuestionsRoundTripThroughJSON() throws {
        for name in AgentQuestionFixture.names {
            let question = try AgentQuestionFixture(name: name).question
            let data = try JSONEncoder().encode(question)
            #expect(try JSONDecoder().decode(AgentQuestion.self, from: data) == question, "\(name)")
        }
    }

    @Test func ordinaryToolPermissionIsNotAQuestion() throws {
        let request: AgentQuestionJSON = [
            "toolCall": ["toolCallId": "t1", "title": "Bash ls", "kind": "execute", "rawInput": ["command": "ls"]],
            "options": [["optionId": "allow_once", "name": "Allow", "kind": "allow_once"]],
        ]
        #expect(AgentQuestion(permissionRequest: request, permissionId: "p", session: "s") == nil)
    }

    @Test func claudeQuestionWithoutUsableItemsIsNotAQuestion() {
        let request: AgentQuestionJSON = [
            "toolCall": ["rawInput": ["questions": [["header": "No prompt"]]], "_meta": ["claude": ["tool": "AskUserQuestion"]]],
            "options": [["optionId": "allow_once", "name": "Answer", "kind": "allow_once"]],
        ]
        #expect(AgentQuestion(permissionRequest: request, permissionId: "p", session: "s") == nil)
    }

    @Test func repeatedOptionLabelsGetUniqueIDs() throws {
        let request: AgentQuestionJSON = [
            "toolCall": ["rawInput": ["questions": [["question": "Pick", "options": [["label": "Same"], ["label": "Same"]]]]],
                         "_meta": ["claude": ["tool": "AskUserQuestion"]]],
        ]
        let question = try #require(AgentQuestion(permissionRequest: request, permissionId: "p", session: "s"))
        #expect(question.items[0].options.map(\.id) == ["Same", "Same#2"])
        #expect(question.items[0].options.map(\.label) == ["Same", "Same"])
    }

    @Test func previewsAreDetectedPerItem() throws {
        #expect(try AgentQuestionFixture(name: "pending-with-preview").question.items[0].hasPreviews)
        #expect(try !AgentQuestionFixture(name: "pending-single").question.items[0].hasPreviews)
    }
}
