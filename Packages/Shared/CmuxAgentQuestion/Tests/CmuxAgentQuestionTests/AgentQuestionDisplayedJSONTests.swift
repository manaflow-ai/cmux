import CmuxAgentQuestion
import Foundation
import Testing

/// The question part's own text travels with a question read from a conversation, so a decision
/// can name exactly what the person was shown, without changing what a question is.
@Suite struct AgentQuestionDisplayedJSONTests {
    static let part = #"{"session":"local/s1","harness":"chief","items":[{"id":"q0","prompt":"Pick","options":[{"id":"a","label":"A"}]}],"state":{"kind":"pending"}}"#

    @Test func aConversationPartKeepsItsDisplayedJSON() throws {
        let json = try AgentQuestionJSON(data: Data(Self.part.utf8))
        let question = try #require(AgentQuestion(conversationPart: json, messageID: "m1", partIndex: 0))
        let shown = try #require(question.displayedJSON)
        #expect(try AgentQuestionJSON(data: Data(shown.utf8)) == json)
    }

    @Test func theDisplayedJSONIsNotPartOfTheQuestion() throws {
        let json = try AgentQuestionJSON(data: Data(Self.part.utf8))
        let read = try #require(AgentQuestion(conversationPart: json, messageID: "m1", partIndex: 0))
        var bare = read
        bare.displayedJSON = nil
        #expect(read == bare && read.hashValue == bare.hashValue)
        let encoded = try JSONEncoder().encode(read)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("displayedJSON"))
        #expect(try JSONDecoder().decode(AgentQuestion.self, from: encoded) == read)
    }
}
