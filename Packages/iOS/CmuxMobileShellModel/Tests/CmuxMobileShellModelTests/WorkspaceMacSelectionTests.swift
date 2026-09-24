import CmuxMobileShellModel
import Testing

struct WorkspaceMacSelectionTests {
    @Test(arguments: [
        (WorkspaceMacSelection.automatic, "automatic"),
        (.all, "all"),
        (.machine("mac-a"), "machine:mac-a"),
        (.machine("mac-a\u{1F}nightly"), "machine:mac-a\u{1F}nightly"),
    ])
    func storedFormatPreservesScopeAndExactIdentity(
        selection: WorkspaceMacSelection,
        storedValue: String
    ) {
        #expect(selection.rawValue == storedValue)
        #expect(WorkspaceMacSelection(rawValue: storedValue) == selection)
    }

    @Test(arguments: ["", "unknown", "machine:"])
    func rejectsInvalidStoredSelection(storedValue: String) {
        #expect(WorkspaceMacSelection(rawValue: storedValue) == nil)
    }
}
