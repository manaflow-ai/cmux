import Testing
@testable import CmuxNextApps

/// The pure scene reducer: op semantics, inline children, budgets.
struct AppSceneTests {
    @Test func createUpdateChildrenRootBuildATree() {
        var scene = AppScene()
        let issues = scene.apply([
            .create(id: "n1", type: "VStack", props: ["spacing": 2]),
            .create(id: "n2", type: "Text", props: ["text": "a", "color": nil]),
            .create(id: "n3", type: "Text", props: ["text": "b"]),
            .children(id: "n1", children: ["n2", "n3"]),
            .root(id: "n1"),
            .update(id: "n2", props: ["text": "A", "color": "secondary"]),
            .update(id: "n3", props: ["text": nil]),
        ])
        #expect(issues.isEmpty)
        #expect(scene.root == "n1")
        #expect(scene["n1"]?.children == ["n2", "n3"])
        #expect(scene["n2"]?.props == ["text": "A", "color": "secondary"])
        #expect(scene["n3"]?.props["text"] == nil)
    }

    @Test func removeDropsTheSubtreeAndDetachesFromTheParent() {
        var scene = AppScene()
        scene.apply([
            .create(id: "r", type: "VStack", props: [:]), .create(id: "g", type: "Group", props: [:]),
            .create(id: "t", type: "Text", props: [:]), .children(id: "g", children: ["t"]),
            .children(id: "r", children: ["g"]), .root(id: "r"), .remove(id: "g"),
        ])
        #expect(scene["g"] == nil)
        #expect(scene["t"] == nil)
        #expect(scene["r"]?.children == [])
        #expect(scene.count == 1)
    }

    @Test func unknownTypesAreIgnoredAndSkippedInChildLists() {
        var scene = AppScene()
        let issues = scene.apply([
            .create(id: "r", type: "VStack", props: [:]), .create(id: "x", type: "Hologram", props: [:]),
            .create(id: "t", type: "Text", props: [:]), .children(id: "r", children: ["x", "t", "t", "missing"]),
            .update(id: "x", props: ["a": 1]), .remove(id: "x"),
        ])
        #expect(issues.isEmpty)
        #expect(scene["x"] == nil)
        #expect(scene["r"]?.children == ["t"])
    }

    @Test func groupAndForEachChildrenFlattenIntoTheParent() {
        var scene = AppScene()
        scene.apply([
            .create(id: "r", type: "VStack", props: [:]), .create(id: "f", type: "ForEach", props: [:]),
            .create(id: "a", type: "Row", props: [:]), .create(id: "b", type: "Row", props: [:]),
            .create(id: "g", type: "Group", props: [:]), .create(id: "e", type: "EmptyState", props: [:]),
            .create(id: "h", type: "HStack", props: [:]),
            .children(id: "f", children: ["a", "b"]), .children(id: "g", children: ["e"]),
            .children(id: "r", children: ["f", "g", "h"]),
        ])
        #expect(scene.flattenedChildren(of: "r") == ["a", "b", "e", "h"])
    }

    @Test func nodeBudgetRefusesCreatesPastFourThousandNinetySix() {
        var scene = AppScene()
        let ops = (0...AppScene.maxNodes).map { AppSceneOp.create(id: "n\($0)", type: "Text", props: [:]) }
        let issues = scene.apply(ops)
        #expect(scene.count == AppScene.maxNodes)
        #expect(issues == [.nodeBudget])
    }

    @Test func depthBudgetRefusesAChainDeeperThanSixtyFour() {
        var scene = AppScene()
        let ids = (0...AppScene.maxDepth).map { "n\($0)" }
        var ops = ids.map { AppSceneOp.create(id: $0, type: "VStack", props: [:]) }
        // Link bottom-up so each op attaches a whole chain: n63 -> n64, then n62 -> n63, ...
        for index in stride(from: ids.count - 2, through: 0, by: -1) { ops.append(.children(id: ids[index], children: [ids[index + 1]])) }
        let issues = scene.apply(ops)
        #expect(issues == [.depthBudget("n1")])
        #expect(scene.depth(of: ids.last!) == AppScene.maxDepth)
    }

    @Test func cyclesAndDuplicateIDsAreRefused() {
        var scene = AppScene()
        let issues = scene.apply([
            .create(id: "a", type: "VStack", props: [:]), .create(id: "b", type: "VStack", props: [:]),
            .children(id: "a", children: ["b"]), .children(id: "b", children: ["a", "b"]),
            .create(id: "a", type: "Text", props: [:]),
        ])
        #expect(scene["b"]?.children == [])
        #expect(issues == [.duplicateID("a")])
    }

    @Test func movingAChildBetweenParentsDetachesItFromTheFirst() {
        var scene = AppScene()
        scene.apply([
            .create(id: "p", type: "VStack", props: [:]), .create(id: "q", type: "VStack", props: [:]),
            .create(id: "c", type: "Text", props: [:]), .children(id: "p", children: ["c"]), .children(id: "q", children: ["c"]),
        ])
        #expect(scene["p"]?.children == [])
        #expect(scene["q"]?.children == ["c"])
    }

    @Test func decodesOpsFromRuntimeJSONSkippingMalformedOnes() throws {
        let json = try AppJSON.parse(#"[{"op":"create","id":"n1","type":"Text","props":{"text":"hi"}},{"op":"bogus","id":"x"},{"op":"root","id":"n1"},{"id":"n2"}]"#)
        #expect(AppSceneOp.batch(json) == [.create(id: "n1", type: "Text", props: ["text": "hi"]), .root(id: "n1")])
    }

    @Test func modelFailsTheMountOnABudgetRefusal() {
        let model = AppSceneModel()
        model.apply([.create(id: "r", type: "Text", props: [:]), .root(id: "r")])
        #expect(model.status == .ready)
        model.apply([.create(id: "r", type: "Text", props: [:])])
        #expect(model.status == .failed("scene op reused node id r"))
    }
}
