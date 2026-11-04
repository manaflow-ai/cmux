import CmuxAgentQuestion
import Foundation
import Testing

/// The shared fixtures (Sources/CmuxAgentQuestion/Fixtures), which the webviews port replays too:
/// each acpmux permission record maps to its expected question.
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
}
