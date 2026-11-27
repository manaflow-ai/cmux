@testable import CmuxNextActions
import Testing

/// Issue manaflow-ai/cmux#25092: one verb opens a terminal of another machine in a chosen
/// place, with a folder (Rex's `split --split=below --cwd`).
@MainActor @Suite struct RemoteOpenTerminalArgumentsTests {
    @Test func openTerminalHereTakesAPlacementAndAFolder() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "remote.openTerminalHere" })
        let names = action.arguments.map(\.name)
        #expect(names.contains("machine"))
        #expect(names.contains("direction"))
        #expect(names.contains("cwd"))
        #expect(action.arguments.first { $0.name == "direction" }?.isRequired == false)
        #expect(action.arguments.first { $0.name == "cwd" }?.isRequired == false)
    }
}
