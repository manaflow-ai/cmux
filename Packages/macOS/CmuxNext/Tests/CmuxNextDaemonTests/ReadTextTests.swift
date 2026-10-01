import Foundation
import Testing
@testable import CmuxNextDaemon

/// `read-scrollback` rows flatten to one text line each, trailing blanks
/// dropped (Search All Windows and the compatibility layer both read them).
struct ReadTextTests {
    @Test func scrollbackRowsFlattenToLines() throws {
        let json = #"{"rows":[{"runs":[{"text":"$ make "},{"text":"build   "}]},{"runs":[]},{"runs":[{"text":"  ok"}]}],"start":4,"total":7}"#
        let page = try JSONDecoder().decode(ReadScrollbackRequest.Response.self, from: Data(json.utf8))
        #expect(page.lines == ["$ make build", "", "  ok"])
        #expect(page.text == "$ make build\n\n  ok")
        #expect(page.start == 4 && page.total == 7)
    }
}
