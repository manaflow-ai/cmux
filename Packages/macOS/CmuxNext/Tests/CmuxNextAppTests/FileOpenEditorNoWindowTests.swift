import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// `cmux file open --where editor PATH` opens this Mac's file in the editor app even when cmux has
/// no window open (no pane): the editor needs none. #25696 made the open look up the pane first, for
/// the Cloud machine check, and with no window it refused "no pane" and opened nothing.
@MainActor @Suite(.serialized)
struct FileOpenEditorNoWindowTests {
    /// Records each open instead of launching an app.
    final class RecordingEditors: AgentPaneEditorApps {
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app")
        var opened: [(file: URL, app: URL)] = []
        func application() -> URL? { app }
        func open(_ url: URL, withApplicationAt app: URL) { opened.append((url, app)) }
    }

    @Test func theCLIOpensAFileInTheEditorWithNoWindowOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file-open-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let editors = RecordingEditors()
        services.editorApps = editors
        #expect(services.windows.controllers.isEmpty, "the case is a cmux with no window")

        let invocation = ActionInvocation(arguments: ["path": .string(file.path), "where": .string("editor")], origin: .cli)
        let refusal = services.registry.capturingRefusal { _ = services.registry.perform(.fileOpen, invocation: invocation) }

        #expect(refusal == nil)
        #expect(editors.opened.map { $0.file.resolvingSymlinksInPath().path } == [file.resolvingSymlinksInPath().path])
        #expect(editors.opened.map(\.app) == [editors.app])
    }
}
