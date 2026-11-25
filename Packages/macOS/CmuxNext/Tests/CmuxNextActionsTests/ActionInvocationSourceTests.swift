import CmuxNextActions
import Testing

/// A file or a data source an action reads or writes (a bookmark file to import or export, a
/// browser to import from) is named by the person or the CLI, never by page script: from a page
/// the action opens its own panel instead.
@Suite struct ActionInvocationSourceTests {
    @Test func aPageNeverNamesAFileOrASource() {
        let args: [String: ActionValue] = ["path": .string("/tmp/victim.html"), "browser": .string("chrome")]
        let page = ActionInvocation(arguments: args, origin: .page)
        #expect(page.callerNamedSource("path") == nil)
        #expect(page.callerNamedSource("browser") == nil)
        for origin in [ActionOrigin.user, .cli, .mcp] {
            #expect(ActionInvocation(arguments: args, origin: origin).callerNamedSource("path") == "/tmp/victim.html")
        }
        #expect(ActionInvocation(arguments: ["path": .string("")], origin: .cli).callerNamedSource("path") == nil)
        #expect(ActionInvocation(arguments: [:], origin: .cli).callerNamedSource("path") == nil)
    }
}
