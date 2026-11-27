import CmuxNextActions
import CmuxNextTerminal
import Testing

/// TextBoxCommand's raw values are copies of catalog action ids that `TextBoxHandlers` turns
/// into `ActionID`s: a renamed catalog id would make Shift-Tab (cycle the submit action) and the
/// Add Files button do nothing, with no error.
@Suite struct TextBoxCommandActionIDTests {
    @Test(arguments: TextBoxCommand.allCases)
    func eachCommandNamesACatalogAction(_ command: TextBoxCommand) {
        let ids = Set(ActionCatalog.all.map(\.id))
        #expect(ids.contains(ActionID(rawValue: command.rawValue)), "\(command) runs \(command.rawValue), which is no catalog action")
    }
}
