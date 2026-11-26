@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A citation's line (#48831): the page asks `link.openPath {path, line?}`, and the line rides to
/// `file.open {where: editor}`. The params come from the page's JSON, so they are parsed from JSON
/// here too: only a whole number from 1 to 10,000,000 is a line, and a bad one refuses the request
/// rather than opening the file somewhere else.
struct AgentPaneOpenPathLineTests {
    private static func request(_ json: String) throws -> AgentPaneReplyRequest? {
        let params = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return AgentPaneReplyRequest(method: "link.openPath", params: params)
    }

    @Test func takesALine() throws {
        #expect(try Self.request(#"{"path":"src/main.rs","line":42}"#) == .openPath("src/main.rs", line: 42))
        #expect(try Self.request(#"{"path":"src/main.rs","line":1}"#) == .openPath("src/main.rs", line: 1))
        #expect(try Self.request(#"{"path":"src/main.rs","line":10000000}"#) == .openPath("src/main.rs", line: 10_000_000))
        // A whole number JSON writes with a fraction is still that line.
        #expect(try Self.request(#"{"path":"src/main.rs","line":7.0}"#) == .openPath("src/main.rs", line: 7))
    }

    @Test func aPathAloneHasNoLine() throws {
        #expect(try Self.request(#"{"path":"src/main.rs"}"#) == .openPath("src/main.rs", line: nil))
    }

    @Test func refusesABadLine() throws {
        for line in ["0", "-1", "1.5", "10000001", "1e300", "true", "false", "null", #""42""#, "[42]", #"{"n":42}"#] {
            #expect(try Self.request(#"{"path":"src/main.rs","line":\#(line)}"#) == nil, "\(line)")
        }
        // A line never stands in for the path.
        #expect(try Self.request(#"{"line":42}"#) == nil)
        #expect(try Self.request(#"{"path":"","line":42}"#) == nil)
    }
}
