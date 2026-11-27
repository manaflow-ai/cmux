import Testing
@testable import CMUXAgentLaunch

@Suite
struct WorkstreamQuestionPromptParsingTests {
    @Test("parses nested questions with rich options")
    func parsesNestedQuestions() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "questions": [{
            "id": "q-choice",
            "header": "Approach",
            "question": "Which one?",
            "multiSelect": true,
            "options": [{"id":"fast","label":"Fast","description":"Ship now"}]
          }]
        }
        """#)

        let question = try #require(parsed.first)
        #expect(question.id == "q-choice")
        #expect(question.header == "Approach")
        #expect(question.prompt == "Which one?")
        #expect(question.multiSelect)
        #expect(question.options == [.init(id: "fast", label: "Fast", description: "Ship now")])
    }

    @Test("parses flat questions and defaults multi-select to false")
    func parsesFlatQuestion() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "prompt": "Choose",
          "options": ["Alpha", "Beta"]
        }
        """#)

        let question = try #require(parsed.first)
        #expect(question.id == "q0")
        #expect(question.prompt == "Choose")
        #expect(!question.multiSelect)
        #expect(question.options == [
            .init(id: "opt0", label: "Alpha"),
            .init(id: "opt1", label: "Beta"),
        ])
    }
}
