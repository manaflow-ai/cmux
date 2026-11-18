import AppKit
import CmuxNextDesign
@testable import CmuxNextBrowser
import Testing

/// The question `browser.pageShortcuts` `ask` asks before a page or cmux gets an app shortcut (CMUX-641).
struct BrowserPageShortcutsPromptTests {
    /// The dialog: a button picks the page or cmux; it names the site, key and focus mode's key.
    @Test func promptAnswersSetTheMode() {
        let prompt = BrowserPageShortcutsPrompt(key: "⌘K", host: "linear.app", focusMode: "⌥⌘↩")
        let spec = prompt.spec
        // No key answers it: the person clicks a button (Lucas 2026-11-18).
        #expect(spec.defaultButton == nil && spec.cancelButton == nil)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == nil)
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == nil)
        let pageAnswer = CmuxDialogAnswer(button: BrowserPageShortcutsPrompt.pageFirst, role: .normal)
        #expect(prompt.mode(for: pageAnswer) == "page")
        #expect(prompt.mode(for: CmuxDialogAnswer(button: BrowserPageShortcutsPrompt.cmuxFirst, role: .normal)) == "cmux")
        #expect(prompt.mode(for: CmuxDialogAnswer(button: "cmux", role: .cancel, isDismissal: true)) == nil, "a closed window set the mode")
        #expect(spec.title.contains("linear.app") && spec.title.contains("⌘K"))
        #expect(spec.lines.contains { $0.contains("linear.app") }, "the answer's scope does not name the site")
        // The check box makes it every site's answer; off, it is this site's.
        #expect(spec.fields.count == 2)
        #expect(!prompt.appliesToAllSites(pageAnswer))
        #expect(prompt.appliesToAllSites(CmuxDialogAnswer(button: "page", role: .default, values: [BrowserPageShortcutsPrompt.allSites: .bool(true)])))
        #expect(spec.lines.count == 1, "the dialog grew past one short line")
        #expect(spec.fields.last == .note("Tip: press ⌘⌥↩ to give a page every key.", danger: false), "the tip is not under the check box")
    }
}
