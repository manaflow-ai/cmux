@testable import CmuxNextApps
import Testing

/// `apps.views` reads the glass a view draws from the window's mirror of its scene, so a script that saves
/// `.glass("chip")` over `.glass("popover")` can be read back reloaded with no rebuild (edit-repaint's
/// `glass` case). An unknown level draws no glass, so it is not reported.
struct AppSceneGlassLevelsTests {
    @Test func glassLevelsListsEachDrawnLevelDepthFirst() {
        var scene = AppScene()
        #expect(scene.glassLevels().isEmpty)
        scene.apply([
            .create(id: "root", type: "VStack", props: ["glass": .string("chrome")]),
            .create(id: "a", type: "HStack", props: ["glass": .string("chip")]),
            .create(id: "a1", type: "Text", props: ["text": .string("inner"), "glass": .string("menu")]),
            .create(id: "b", type: "Text", props: ["text": .string("plain")]),
            .create(id: "c", type: "Text", props: ["glass": .string("frosted")]),
            .create(id: "d", type: "Text", props: ["glass": .string("popover")]),
            .children(id: "a", children: ["a1"]),
            .children(id: "root", children: ["a", "b", "c", "d"]),
            .root(id: "root"),
        ])
        #expect(scene.glassLevels() == ["chrome", "chip", "menu", "popover"])

        scene.apply([.update(id: "a", props: ["glass": .string("popover")])])
        #expect(scene.glassLevels() == ["chrome", "popover", "menu", "popover"])
        scene.apply([.update(id: "a", props: ["glass": .null])])
        #expect(scene.glassLevels() == ["chrome", "menu", "popover"])
    }
}
