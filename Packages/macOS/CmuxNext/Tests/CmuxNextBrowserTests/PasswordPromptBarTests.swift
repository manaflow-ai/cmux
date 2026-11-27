import AppKit
@testable import CmuxNextBrowser
import Testing

/// The save-password prompt bar (cx-d0d.13, #20049 review): a save prompt offers Never for
/// This Site, Not Now and Save. An update prompt is for a sign-in already saved, so it offers
/// only Not Now and Update, like Chromium's own update bubble; Never there would put a site
/// with a saved password on the never-save list.
@MainActor @Suite(.serialized) struct PasswordPromptBarTests {
    static func answers(update: Bool) -> [String] {
        let bar = PromptBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        bar.show(BrowserPrompt(kind: .savePassword(username: "someone", update: update), origin: "https://example.com") { _ in })
        return responseButtons(in: bar).map { String(describing: $0.response) }
    }

    static func responseButtons(in view: NSView) -> [PromptResponseButton] {
        view.subviews.flatMap { subview in (subview as? PromptResponseButton).map { [$0] } ?? responseButtons(in: subview) }
    }

    @Test func aSavePromptOffersNeverNotNowAndSave() {
        #expect(Self.answers(update: false) == [String(describing: BrowserPromptResponse?.some(.deny)),
                                                String(describing: BrowserPromptResponse?.some(.cancel)),
                                                String(describing: BrowserPromptResponse?.some(.accept))])
    }

    @Test func anUpdatePromptOffersNoNever() {
        #expect(Self.answers(update: true) == [String(describing: BrowserPromptResponse?.some(.cancel)),
                                               String(describing: BrowserPromptResponse?.some(.accept))])
    }
}
