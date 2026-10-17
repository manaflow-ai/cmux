import Foundation
import Testing

@testable import CmuxAgentChat

struct ChatAgentKindTests {
    @Test("OpenCode is a first-class chat provider on the wire")
    func opencodeRoundTrips() throws {
        let kind = ChatAgentKind(source: "opencode")
        #expect(kind == .opencode)
        #expect(kind.sourceName == "opencode")
        #expect(kind.displayName == "OpenCode")

        let data = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(ChatAgentKind.self, from: data) == .opencode)
    }

    @Test("Unknown providers remain fail-open")
    func unknownProviderRemainsOther() {
        #expect(ChatAgentKind(source: "future-agent") == .other("future-agent"))
    }
}
