import Testing
@testable import CmuxSwiftRender

@Suite struct SidebarWorkspaceCreateActionTests {
    @Test func capturesQualifiedWorkspaceCreateActionWithCommand() {
        let node = SwiftViewInterpreter().evaluate("""
        Button("essai") {
            workspace.create(title: "essai", cwd: ".", command: "echo hello")
        }
        """)

        #expect(
            node?.action?.commands == [
                .cmux(
                    method: "workspace.create",
                    params: [
                        "title": "essai",
                        "cwd": ".",
                        "command": "echo hello",
                    ]
                ),
            ]
        )
    }

    @Test func encodesNonFiniteStructuredValuesAsValidJSONNull() {
        let node = SwiftViewInterpreter().evaluate("""
        Button("essai") {
            cmux("workspace.create", layout: ["split": 1.0 / 0.0])
        }
        """)

        #expect(
            node?.action?.commands == [
                .cmux(
                    method: "workspace.create",
                    params: ["layout": #"{"split":null}"#]
                ),
            ]
        )
    }

    @Test func ignoresUnrecognizedQualifiedCalls() {
        let node = SwiftViewInterpreter().evaluate("""
        Button("essai") {
            state.reset()
        }
        """)

        #expect(node?.action?.commands.isEmpty == true)
    }
}
