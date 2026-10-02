import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// A browser tab opened from a terminal opens its dev server (#16620).
@Suite struct WorkingURLTests {
    @Test func theNewestLocalServerOnScreenWins() {
        let screen = """
        docs: https://example.com/guide
          ➜  Local:   http://localhost:5173/
        restarted on http://127.0.0.1:3000/app.
        """
        #expect(WorkingURL.devServer(in: screen) == URL(string: "http://127.0.0.1:3000/app"))
    }

    @Test func aBindAddressBecomesLocalhost() {
        #expect(WorkingURL.devServer(in: "listening on http://0.0.0.0:8080/") == URL(string: "http://localhost:8080/"))
    }

    @Test func noLocalServerMeansABlankTab() {
        #expect(WorkingURL.devServer(in: "see https://github.com/manaflow-ai/cmux/pull/1") == nil)
        #expect(WorkingURL.devServer(in: nil) == nil)
    }
}
