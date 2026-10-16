import Foundation
import Testing
@testable import CmuxCEF

@Suite
struct CEFBrowserPopupTests {
    @MainActor @Test
    func createdPopupTargetURLSeedsTheAdoptedBrowserState() throws {
        let runtime = CEFRuntime(layout: nil)
        let opener = CEFBrowser(
            configuration: CEFBrowserConfiguration(profile: UUID(), initialURL: URL(string: "https://example.com/")),
            runtime: runtime
        )
        let target = try #require(URL(string: "https://chromewebstore.google.com/detail/example"))

        let popup = CEFBrowser(adopting: 42, from: opener, runtime: runtime, targetURL: target)

        #expect(popup.state.url == target)
        #expect(popup.configuration.initialURL == nil)
    }

    @Test
    func afterCreatedEventCarriesThePopupTargetURL() throws {
        let event = CEFShimEvent(
            kind: 2,
            browser: 42,
            request: 0,
            a: 0,
            b: (Int64(7) << 32) | (Int64(1) << 16) | Int64(3),
            s1: "",
            s2: "https://chromewebstore.google.com/detail/example"
        )

        guard case .afterCreated(_, _, _, let created) = event else {
            Issue.record("Expected AFTER_CREATED event")
            return
        }
        #expect(created.url == "https://chromewebstore.google.com/detail/example")
        #expect(created.opener == 7)
        #expect(created.disposition == .newForegroundTab)
        #expect(created.userGesture)
    }
}
