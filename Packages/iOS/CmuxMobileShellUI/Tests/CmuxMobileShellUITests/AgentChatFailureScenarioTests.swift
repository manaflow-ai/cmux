#if DEBUG && os(iOS)
import CmuxAgentChat
import Testing

@testable import CmuxMobileShellUI

@Suite
struct AgentChatFailureScenarioTests {
    @Test
    func exposesEveryTypedArtifactFailure() {
        let scenarios = AgentChatFailureScenario.allCases
        #expect(scenarios.count == 32)
        #expect(Set(scenarios.map(\.rawValue)).count == scenarios.count)
        #expect(Set(scenarios.map(\.title)).count > 1)
        #expect(scenarios.contains(.fileNotFound))
        #expect(scenarios.contains(.macUnreachable))
        #expect(scenarios.contains(.tooLarge))
    }

    @Test
    func fixtureLoaderPreservesSelectedTypedError() async {
        let loader = AgentChatFailureScenario.fileNotFound.loader
        await #expect(throws: ChatArtifactError.fileNotFound) {
            try await loader.stat(path: "/tmp/cmux-attachments/ci-failure.png")
        }
    }
}
#endif
