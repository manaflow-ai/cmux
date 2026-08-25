import Foundation
import Testing
@testable import CmuxSwiftRender

/// Context-menu bodies are view-builder closures in SwiftUI. The interpreter
/// must retain those closures without walking them during every row render.
@Suite struct DeferredContextMenuTests {
    private let interpreter = SwiftViewInterpreter()

    @Test func contextMenuBodyIsNotEvaluatedWithTheRow() {
        let node = interpreter.evaluate("""
        VStack {
            ForEach(0..<30) { i in
                Text("Row \\(i)").contextMenu {
                    Button("Open \\(i)") { cmux("workspace.select", workspace_id: \\(i)) }
                    Menu("Color") {
                        Button("Blue") { cmux("workspace.color", color: "blue") }
                    }
                }
            }
        }
        """)

        let modifiers = node?.children.compactMap { child in
            child.modifiers.first { $0.name == "contextMenu" }
        } ?? []
        #expect(modifiers.count == 30)
        #expect(modifiers.allSatisfy { $0.hasDeferredContent })
        #expect(modifiers.allSatisfy { $0.children.isEmpty })
    }

    @Test func contextMenuBodyMaterializesOnceAndPreservesBindings() throws {
        let node = try #require(interpreter.evaluate("""
        VStack {
            ForEach(0..<2) { i in
                Text("Row \\(i)").contextMenu {
                    Button("Open \\(i)") { cmux("workspace.select", workspace_id: \\(i)) }
                }
            }
        }
        """))
        let modifier = try #require(node.children[1].modifiers.first { $0.name == "contextMenu" })

        let first = modifier.materializedChildren()
        let second = modifier.materializedChildren()
        #expect(first == second)
        #expect(first.first?.text == "Open 1")
        #expect(first.first?.action?.commands.count == 1)
    }

    @Test func encodingMaterializesDeferredContentForTransport() throws {
        let node = try #require(interpreter.evaluate("""
        Text("Row").contextMenu {
            Button("Open") { cmux("workspace.select") }
        }
        """))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(RenderNode.self, from: data)
        let modifier = try #require(decoded.modifiers.first { $0.name == "contextMenu" })

        #expect(!modifier.hasDeferredContent)
        #expect(modifier.children.first?.text == "Open")
    }
}
