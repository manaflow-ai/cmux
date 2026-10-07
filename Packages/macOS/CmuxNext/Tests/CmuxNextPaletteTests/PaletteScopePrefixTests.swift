@testable import CmuxNextPalette
import Testing

/// User-assigned prefixes over the built-in scopes (D-PS4): the user's
/// character wins and moves from the scope that had it by default.
@Suite struct PaletteScopePrefixTests {
    var builtIns: [PaletteScopeDescriptor] { PaletteScopeDescriptor.builtIns(tabs: true, workspaces: true, settings: true) }

    func prefixes(_ scopes: [PaletteScopeDescriptor]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: scopes.compactMap { scope in scope.prefix.map { (scope.id.rawValue, $0) } })
    }

    @Test func defaultsMatchTheSettingsSchema() {
        #expect(prefixes(builtIns) == ["tabs": "@", "workspaces": "#", "commands": ">", "settings": ",", "scopes": "?"])
    }

    @Test func anAssignedPrefixMovesFromItsDefaultOwner() {
        let scopes = PaletteController.applying([.workspaces: "@"], to: builtIns)
        #expect(prefixes(scopes)["workspaces"] == "@")
        #expect(prefixes(scopes)["tabs"] == nil)
        let graph = PaletteScopeGraph(root: .paletteRoot, scopes: scopes)
        #expect(graph.problems.isEmpty)
        #expect(graph.child(of: .root, prefix: "@")?.id == .workspaces)
    }

    @Test func noneTurnsAPrefixOffAndAnInvalidOneIsIgnored() {
        let assigned: [PaletteScopeID: String?] = [.tabs: nil, .commands: "x"]
        let scopes = PaletteController.applying(assigned, to: builtIns)
        #expect(prefixes(scopes)["tabs"] == nil)
        #expect(prefixes(scopes)["commands"] == ">")
    }

    @Test func aModelUsesTheAssignedPrefix() {
        let reducer = PaletteNavReducer(graph: PaletteScopeGraph(root: .paletteRoot,
                                                                 scopes: PaletteController.applying([.workspaces: "@"], to: builtIns)))
        var state = PaletteNavState()
        _ = reducer.reduce(&state, .open(scope: nil, query: ""))
        _ = reducer.reduce(&state, .setQuery("@"))
        #expect(state.scopePath == [.root, .workspaces])
    }
}
