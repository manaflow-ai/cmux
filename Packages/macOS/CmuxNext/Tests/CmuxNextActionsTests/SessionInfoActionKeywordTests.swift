import Testing
@testable import CmuxNextActions

/// Session Info is not an inspector (Leo, 2026-11-02: "I FUCKING HATE ALL OF YOU HAVING THAT INSPECTOR NAME
/// IT BETTER NOT STILL BE IN THERE"). The Event Inspector and Chief Memory Inspector keep the word.
@Suite
struct SessionInfoActionKeywordTests {
    @Test("no Session Info action answers to inspector")
    func sessionInfoActionsAreNotInspectors() {
        let sessionInfo = AgentActionCatalog.descriptors().filter { $0.keywords.contains("session info") }
        #expect(!sessionInfo.isEmpty)
        for descriptor in sessionInfo {
            #expect(!descriptor.keywords.contains("inspector"), "\(descriptor.id) still lists inspector")
        }
    }
}
