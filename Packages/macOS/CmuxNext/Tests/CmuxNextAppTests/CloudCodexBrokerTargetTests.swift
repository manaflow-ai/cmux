import Foundation
import Testing
@testable import CmuxNextCloud

@Suite("Cloud Codex broker target")
struct CloudCodexBrokerTargetTests {
    @Test func readsPrettyPrintedRunningDaemonCapabilities() {
        let output = "{\n  \"capabilities\": [\n    \"codex-external-access-v1\"\n  ]\n}"
        #expect(CloudCodexBrokerTarget.supportsExternalAccess(output))
        #expect(!CloudCodexBrokerTarget.supportsExternalAccess("{\"capabilities\":[]}"))
    }

}
