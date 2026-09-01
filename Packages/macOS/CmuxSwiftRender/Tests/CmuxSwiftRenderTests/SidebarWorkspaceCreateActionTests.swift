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
}
