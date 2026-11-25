import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextWindowRules
import Foundation
import Testing

/// `cmux file open --where editor PATH` opens this Mac's file in the editor app even when cmux has
/// no window open (no pane): the editor needs none. #25696 made the open look up the pane first, for
/// the Cloud machine check, and with no window it refused "no pane" and opened nothing.
@MainActor @Suite(.serialized)
struct FileOpenEditorNoWindowTests {
    /// Records each open instead of launching an app.
    final class RecordingEditors: AgentPaneEditorApps {
        let app: URL
        var opened: [(file: URL, app: URL)] = []
        init(app: URL = URL(fileURLWithPath: "/Applications/TextEdit.app")) { self.app = app }
        func application() -> URL? { app }
        func open(_ url: URL, withApplicationAt app: URL) { opened.append((url, app)) }
    }

    @Test func editorLocationPreservesTheFileAndLine() throws {
        let file = URL(fileURLWithPath: "/tmp/space #100%/résumé.swift")
        let editors = [
            "com.microsoft.VSCode": "vscode", "com.todesktop.230313mzl4w4u92": "cursor",
            "com.exafunction.windsurf": "windsurf", "dev.zed.Zed": "zed",
        ]
        // The schemes come from the app FFI's editor_schemes; a pin without them opens the plain file.
        for (bundleID, scheme) in editors where WindowRules.chatAgentTables?.editorSchemes != nil {
            let url = WindowRules.editorLocation(for: file, line: 42, bundleID: bundleID)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.scheme == scheme)
            #expect(parts.host == "file")
            #expect(parts.path == file.path + ":42")
            #expect(parts.fragment == nil)
        }
        #expect(WindowRules.editorLocation(for: file, line: 42, bundleID: "com.apple.TextEdit") == file)
        #expect(WindowRules.editorLocation(for: file, line: nil, bundleID: "dev.zed.Zed") == file)
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

    /// A fake editor app: a bundle with only the Info.plist `Bundle(url:)` reads its ID from.
    private static func editorBundle(_ bundleID: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent("Editor.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL", "CFBundleName": "Editor"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    /// Opens `file` through `file.open {where: editor}` with `line` in the invocation, in an editor with
    /// `bundleID`, and answers what the editor was handed.
    private static func openInEditor(bundleID: String, line: Int?) throws -> (opened: [(file: URL, app: URL)], file: URL, app: URL) {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("file-open-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        let folder = made.resolvingSymlinksInPath()
        let file = folder.appendingPathComponent("main.swift")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        let app = try editorBundle(bundleID, in: folder)

        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let editors = RecordingEditors(app: app)
        services.editorApps = editors
        var invocation = ActionInvocation(arguments: ["path": .string(file.path), "where": .string("editor")], origin: .cli)
        invocation.editorLine = line
        let refusal = services.registry.capturingRefusal { _ = services.registry.perform(.fileOpen, invocation: invocation) }
        #expect(refusal == nil)
        return (editors.opened, file, app)
    }

    /// The handler hands the editor the cited line (#48831): the location `WindowRules.editorLocation`
    /// makes for this file, line and the chosen app's bundle ID, in that app. Which editors get a
    /// `scheme://file/<path>:<line>` URL is the rules' table (``editorLocationPreservesTheFileAndLine()``).
    @Test func theEditorLineOpensTheFileAtThatLine() throws {
        let run = try Self.openInEditor(bundleID: "dev.zed.Zed", line: 3)
        #expect(run.opened.count == 1)
        let opened = try #require(run.opened.first)
        #expect(opened.app == run.app)
        #expect(opened.file.absoluteString == WindowRules.editorLocation(for: run.file, line: 3, bundleID: "dev.zed.Zed").absoluteString)
        if WindowRules.chatAgentTables?.editorSchemes?["dev.zed.zed"] != nil {
            let parts = try #require(URLComponents(url: opened.file, resolvingAgainstBaseURL: false))
            #expect(parts.scheme == "zed")
            #expect(parts.path == run.file.path + ":3")
        }
    }

    /// No line, or an editor with no location scheme: the checked file itself, as before #48831.
    @Test(arguments: [("dev.zed.Zed", nil), ("com.apple.TextEdit", 3)] as [(String, Int?)])
    func withoutALineSchemeTheEditorGetsThePlainFile(bundleID: String, line: Int?) throws {
        let run = try Self.openInEditor(bundleID: bundleID, line: line)
        #expect(run.opened.map { $0.file.resolvingSymlinksInPath().path } == [run.file.path])
        #expect(run.opened.first?.file.isFileURL == true)
        #expect(run.opened.map(\.app) == [run.app])
    }
}
