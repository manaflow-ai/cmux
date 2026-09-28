import Foundation
import Testing

@testable import CmuxSettings

@Suite("First-run base keymap chooser")
struct ShortcutKeymapChooserTests {
    @Test("A fresh install is asked which keymap it wants")
    func freshInstallOpensTheChooser() {
        let decision = ShortcutKeymapChooserPolicy.decide(
            hasAnsweredChooser: false,
            installHasHistory: false
        )
        #expect(decision == .open)
    }

    @Test("An install that predates the chooser is never asked")
    func installWithHistoryIsNeverAsked() {
        let decision = ShortcutKeymapChooserPolicy.decide(
            hasAnsweredChooser: false,
            installHasHistory: true
        )
        #expect(decision == .skipExistingInstall)
    }

    @Test("Answering wins over install history, so answering once is enough")
    func answeringWinsOverInstallHistory() {
        // A fresh install answers the chooser and then writes its first
        // config file, which makes it look like an install with history on the
        // next launch. It must still count as answered, not be asked again.
        let decision = ShortcutKeymapChooserPolicy.decide(
            hasAnsweredChooser: true,
            installHasHistory: true
        )
        #expect(decision == .alreadyAnswered)
    }

    @Test("Only a fresh unanswered install opens the chooser")
    func openIsTheOnlyDecisionThatShows() {
        let opening = ShortcutKeymapChooserDecision.allCases.filter { decision in
            switch decision {
            case .open: return true
            case .skipExistingInstall, .alreadyAnswered: return false
            }
        }
        #expect(opening == [.open])
    }

    @Test("Every preset previews the same actions in the same order",
          arguments: ShortcutKeymapPreset.allCases)
    func everyPresetPreviewsTheSameRows(preset: ShortcutKeymapPreset) {
        // The chooser reads as a column comparison, so a preset that dropped
        // or reordered a row would misalign the preview.
        #expect(preset.highlights().map(\.action) == ShortcutKeymapPreset.highlightActions)
    }

    @Test("A preview row is marked written exactly when the preset writes it",
          arguments: ShortcutKeymapPreset.allCases)
    func writtenFlagMatchesTheOverrides(preset: ShortcutKeymapPreset) {
        for highlight in preset.highlights() {
            let override = preset.overrides[highlight.action]?.shortcut
            #expect(highlight.isWrittenByPreset == (override != nil))
            if let override {
                #expect(highlight.shortcut == override.canonicalized())
            } else {
                let fallback = highlight.action.defaultShortcut(using: .builtIn) ?? .unbound
                #expect(highlight.shortcut == fallback.canonicalized())
            }
        }
    }

    @Test("The cmux preset previews the defaults and writes nothing")
    func cmuxPresetPreviewIsAllDefaults() {
        let highlights = ShortcutKeymapPreset.cmux.highlights()
        #expect(highlights.allSatisfy { !$0.isWrittenByPreset })
    }

    @Test("The browser preview shows the tab keys it writes and the keys it keeps")
    func browserPresetPreviewShowsTheTabKeys() throws {
        let highlights = ShortcutKeymapPreset.browser.highlights()
        let byAction = Dictionary(
            uniqueKeysWithValues: highlights.map { ($0.action, $0) }
        )

        let next = try #require(byAction[.nextSurface])
        #expect(next.shortcut == StoredShortcut(first: ShortcutStroke(key: "\t", control: true)))
        #expect(next.isWrittenByPreset)

        let previous = try #require(byAction[.prevSurface])
        #expect(previous.shortcut == StoredShortcut(
            first: ShortcutStroke(key: "\t", control: true, shift: true)
        ))
        #expect(previous.isWrittenByPreset)

        // Cmd-T and Cmd-W already match a browser, so the preview shows them
        // as kept rather than changed.
        #expect(byAction[.newSurface]?.isWrittenByPreset == false)
        #expect(byAction[.closeTab]?.isWrittenByPreset == false)
    }

    @Test("The numbered rows render as a range, not as a bare 1")
    func numberedRowsAreMarkedAsRanges() {
        let numbered = ShortcutKeymapPreset.browser.highlights()
            .filter(\.usesNumberedDigitRange)
            .map(\.action)
        #expect(Set(numbered) == [.selectSurfaceByNumber, .selectWorkspaceByNumber])
    }
}
