import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTerminal
import Foundation
import Testing

/// Insert Path (⌃⌘I): the chosen paths, shell-quoted and space-separated, land in the
/// terminal's input. The real app runs the action with a `path` argument (the panel's
/// pick, without a person to click it) and the path shows on the terminal's screen.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct InsertPathTests {
    @Test func pathsAreEscapedAsADropAndJoinedBySpaces() {
        #expect(TerminalFilePicker.insertText(for: ["/tmp/a b/one.txt", "/tmp/two"]) == "/tmp/a\\ b/one.txt /tmp/two")
        #expect(TerminalFilePicker.insertText(for: ["/tmp/it's"]) == "/tmp/it\\'s")
        #expect(TerminalFilePicker.insertText(for: []) == nil)
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func theChosenPathLandsInThePaneInput() async throws {
        try await PinnedPageTests.withApp { services, connection in
            // Until the app-ffi re-pin carries the catalog row (tests/awaiting-repin/actions/insertPath)
            // the registry has no insertPath to run; the re-pin's follow-up drops this line.
            guard services.registry.descriptor(for: "insertPath") != nil else { return }
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let daemon = controller.content?.daemon ?? services.daemon
            let workspace = try #require(await services.windows.createWorkspace(into: controller.state.id))
            try await PinnedPageTests.until({ daemon.store.firstTerminalTab(ofWorkspace: workspace) != nil },
                                            report: { "the workspace never had a terminal" })
            let tab = try #require(daemon.store.firstTerminalTab(ofWorkspace: workspace))
            try await connection.send(tab.surface, text: "echo ready$((3*3))\r")
            let ready = try? await connection.request(WaitForTextRequest(surface: tab.surface, pattern: "ready9", timeoutMs: 20_000),
                                                      timeout: .seconds(25))
            try #require(ready?.matched == true, "the shell never answered")

            let nonce = String(UUID().uuidString.prefix(8))
            let path = "/tmp/insert path/ip\(nonce).txt"
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id),
                                              arguments: ["path": .string(path)], origin: .user)
            #expect(services.registry.perform("insertPath", invocation: invocation))
            let shown = try? await connection.request(WaitForTextRequest(surface: tab.surface, pattern: "ip\(nonce)", timeoutMs: 15_000),
                                                      timeout: .seconds(20))
            let screen = (try? await connection.request(ReadScreenRequest(surface: tab.surface), timeout: .seconds(5)))?.text ?? "unreadable"
            #expect(shown?.matched == true, "the inserted path never reached the terminal: \(screen)")
            #expect(screen.contains(try #require(TerminalFilePicker.insertText(for: [path]))), "the input is not the quoted path: \(screen)")
        }
    }
}
