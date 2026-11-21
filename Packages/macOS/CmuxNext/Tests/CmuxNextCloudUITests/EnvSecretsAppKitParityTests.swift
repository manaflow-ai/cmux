#if DEBUG
import AppKit
@testable import CmuxNextCloudUI
import Testing

/// Environment Secrets Playground in AppKit: the places it drew differently from its SwiftUI first version,
/// checked on the drawn view (``EnvRenderedPage``).
@MainActor @Suite struct EnvSecretsAppKitParityTests {
    /// Sentences, Terminal state: the whole page holds both terminal frames, every line in full (wrapped where
    /// the 680-point column is too narrow), none cut off with an ellipsis.
    @Test func sentencesTerminalShowsEveryLineInFull() throws {
        let model = EnvSecretsPlaygroundModel()
        model.direction = .sentences
        model.scene = .cli
        let page = try EnvRenderedPage(model, size: CGSize(width: 1180, height: 2400))
        #expect(page.cutLines.isEmpty, "lines cut off: \(page.cutLines)")
        // Line ends the text recognition reads reliably on the dark frames: the list's last column title,
        // the last row's last word, and the last line's middle.
        for tail in ["LAST USE", "never", "shown again"] {
            #expect(page.text.contains(tail), "\"\(tail)\" is drawn")
        }
    }

    /// Inspector, Paste state: in a narrow window the type notes wrap onto a second line, none cut off.
    @Test func inspectorTypeNotesWrapInANarrowWindow() throws {
        let model = EnvSecretsPlaygroundModel()
        model.scene = .paste
        let view = EnvInspectorDirection(model: model, reload: {}).make()
        let page = try EnvRenderedPage(view: view, size: CGSize(width: 640, height: 900))
        #expect(page.cutLines.isEmpty, "lines cut off: \(page.cutLines)")
        #expect(page.text.contains("only to the hosts below."), "the API secret note is drawn to its end")
        #expect(page.text.contains("before the agent starts."), "the setup note is drawn to its end")
    }

    /// Sentences, Saved state: the highlighted card (the open secret) has a 1.5-point border, as the plain
    /// cards' 1-point border is not.
    @Test func sentencesHighlightedCardBorderIsOneAndAHalfPoints() throws {
        let model = EnvSecretsPlaygroundModel()
        model.direction = .sentences
        model.scene = .saved
        let page = try EnvRenderedPage(model)
        let title = try #require(page.line(containing: "STRIPE_SECRET_KEY"), "the highlighted card's title is drawn")
        #expect(page.accentEdgeWidth(leftOf: title) == 1.5, "border \(page.accentEdgeWidth(leftOf: title)) pt")
    }
}
#endif
