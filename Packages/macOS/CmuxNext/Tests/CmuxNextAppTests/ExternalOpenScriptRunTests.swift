import CmuxNextDesign
import CmuxNextOnboarding
import Foundation
import Testing

/// A script or an executable file opened with cmux (Finder, `open`, a drop on the Dock icon) is
/// run only after the person says yes, and a file macOS marked as downloaded from the internet
/// (`com.apple.quarantine`) is not run at all. The opened file comes from another app, so the
/// open itself is not the person's consent to run it.
@Suite struct ExternalOpenScriptRunTests {
    static let scriptShells = ["command": "sh", "tool": "sh", "sh": "sh", "zsh": "zsh", "bash": "bash", "csh": "csh", "pl": "perl"]

    @Test(arguments: ["command", "tool", "sh", "zsh", "bash", "csh", "pl"])
    func anOpenedScriptRunsNothingBeforeAYes(ext: String) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.file("run me.\(ext)", in: folder)
        let shell = try #require(Self.scriptShells[ext])
        for executable in [true, false] {
            let route = ExternalOpenRouter(isExecutable: { _ in executable }).route(file)
            #expect(Self.typedCommand(route) == nil, "opening .\(ext) types a command at once: \(route)")
            let request = try #require(Self.runRequest(route), "opening .\(ext) asks nothing: \(route)")
            #expect(request.path == file.path)
            #expect(request.cwd == folder.path)
            #expect(request.command == (executable ? ShellQuote.quote(file.path) : "\(shell) \(ShellQuote.quote(file.path))"))
            #expect(request.quarantined == false)
        }
    }

    @Test func anOpenedExecutableWithNoExtensionRunsNothingBeforeAYes() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.file("tool", in: folder)
        let route = ExternalOpenRouter(isExecutable: { _ in true }).route(file)
        #expect(Self.typedCommand(route) == nil, "opening an executable types a command at once: \(route)")
        let request = try #require(Self.runRequest(route), "opening an executable asks nothing: \(route)")
        #expect(request.path == file.path)
        #expect(request.cwd == folder.path)
        #expect(request.command == ShellQuote.quote(file.path))
        #expect(request.quarantined == false)
    }

    /// The default router reads the file's own quarantine attribute.
    @Test(arguments: ["run.command", "run.sh", "tool"])
    func aDownloadedFileIsRefused(name: String) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.file(name, in: folder, quarantined: true)
        let route = ExternalOpenRouter(isExecutable: { _ in true }).route(file)
        #expect(Self.typedCommand(route) == nil, "opening a downloaded \(name) types a command at once: \(route)")
        let request = try #require(Self.runRequest(route), "opening a downloaded \(name) asks nothing: \(route)")
        #expect(request.quarantined, "a downloaded \(name) is not refused: \(route)")
    }

    @Test func aFolderStillOpensATerminalThereWithNoCommand() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ExternalOpenRouter().route(folder) == .terminal(cwd: folder.path, command: nil))
    }

    @Test func aDocumentStillOpensInTheFileOpener() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.file("notes.txt", in: folder, quarantined: true)
        #expect(ExternalOpenRouter(isExecutable: { _ in true }).route(file) == .file(file))
    }

    @Test func theQuarantineCheckIsTheRoutersInjectedOne() {
        let router = ExternalOpenRouter(isDirectory: { _ in false }, isExecutable: { _ in true }, isQuarantined: { $0 == "/Downloads/get.sh" })
        #expect(router.route(URL(fileURLWithPath: "/Downloads/get.sh"))
            == .confirmRun(path: "/Downloads/get.sh", cwd: "/Downloads", command: "'/Downloads/get.sh'", quarantined: true))
        #expect(router.route(URL(fileURLWithPath: "/work/build.sh"))
            == .confirmRun(path: "/work/build.sh", cwd: "/work", command: "'/work/build.sh'", quarantined: false))
    }

    // MARK: The question (`OpenedScriptConfirmation`)

    /// What the question did: the spec it showed and what ran or was revealed after the answer.
    @MainActor final class Probe {
        var shown: [CmuxDialogSpec] = []
        var answer: ((CmuxDialogAnswer) -> Void)?
        var runs: [String] = []
        var reveals: [URL] = []

        func ask(_ request: OpenedScriptConfirmation) {
            request.ask(present: { spec, done in self.shown.append(spec); self.answer = done },
                        run: { cwd, typing in self.runs.append("\(cwd)|\(typing)") },
                        reveal: { self.reveals.append($0) })
        }

        func press(_ button: String, role: CmuxDialogButton.Role = .normal, dismissal: Bool = false) {
            answer?(CmuxDialogAnswer(button: button, role: role, isDismissal: dismissal))
        }
    }

    static let script = OpenedScriptConfirmation(path: "/work/run me.command", cwd: "/work", command: "'/work/run me.command'", quarantined: false)

    @MainActor @Test func theQuestionNamesTheFileAndCancelIsTheSafeKey() throws {
        let spec = Self.script.spec
        #expect(spec.title.contains("run me.command"))
        #expect(spec.lines.contains("/work/run me.command"))
        #expect(spec.cancelButton?.id == "cancel")
        // Return presses nothing: only a press of Run runs the file.
        #expect(spec.defaultButton == nil)
        let run = try #require(spec.buttons.first { $0.id == OpenedScriptConfirmation.runButton })
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == nil)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("cancel"))
        #expect(run.key == nil)
    }

    @MainActor @Test func nothingRunsBeforeTheAnswerAndCancelRunsNothing() {
        let probe = Probe()
        probe.ask(Self.script)
        #expect(probe.shown.count == 1)
        #expect(probe.runs.isEmpty)
        probe.press("cancel", role: .cancel)
        #expect(probe.runs.isEmpty)
        #expect(probe.reveals.isEmpty)
    }

    @MainActor @Test func aClosedQuestionRunsNothing() {
        let probe = Probe()
        probe.ask(Self.script)
        probe.press(OpenedScriptConfirmation.runButton, role: .destructive, dismissal: true)
        #expect(probe.runs.isEmpty)
    }

    @MainActor @Test func runTypesTheCommandInTheFilesFolder() {
        let probe = Probe()
        probe.ask(Self.script)
        probe.press(OpenedScriptConfirmation.runButton, role: .destructive)
        #expect(probe.runs == ["/work|'/work/run me.command'\n"])
    }

    @MainActor @Test func aDownloadedFileGetsNoRunButtonAndNoAnswerRunsIt() {
        var request = Self.script
        request.quarantined = true
        let spec = request.spec
        #expect(spec.identifier == OpenedScriptConfirmation.refusalIdentifier)
        #expect(spec.title.contains("run me.command"))
        #expect(spec.lines.contains("/work/run me.command"))
        #expect(!spec.buttons.contains { $0.id == OpenedScriptConfirmation.runButton })
        let probe = Probe()
        probe.ask(request)
        // An answer naming Run (automation answers by button id) still runs nothing.
        probe.press(OpenedScriptConfirmation.runButton, role: .destructive)
        probe.press("ok", role: .default)
        #expect(probe.runs.isEmpty)
        #expect(probe.reveals.isEmpty)
    }

    @MainActor @Test func showInFinderRevealsTheDownloadedFile() {
        var request = Self.script
        request.quarantined = true
        let probe = Probe()
        probe.ask(request)
        probe.press(OpenedScriptConfirmation.showInFinderButton)
        #expect(probe.reveals == [URL(fileURLWithPath: "/work/run me.command")])
        #expect(probe.runs.isEmpty)
    }

    // MARK: Helpers

    /// What the open types into a new terminal tab at once, if anything.
    static func typedCommand(_ route: ExternalOpenRoute) -> String? {
        if case .terminal(_, let command) = route { return command }
        return nil
    }

    struct RunRequest {
        var path: String
        var cwd: String
        var command: String
        var quarantined: Bool
    }

    /// The run the route asks the person about (`.confirmRun`), read by reflection so this file
    /// also builds against a router that has no such route.
    static func runRequest(_ route: ExternalOpenRoute) -> RunRequest? {
        guard let payload = Mirror(reflecting: route).children.first, payload.label == "confirmRun" else { return nil }
        var fields: [String: Any] = [:]
        for field in Mirror(reflecting: payload.value).children {
            if let label = field.label { fields[label] = field.value }
        }
        guard let path = fields["path"] as? String, let cwd = fields["cwd"] as? String,
              let command = fields["command"] as? String, let quarantined = fields["quarantined"] as? Bool else { return nil }
        return RunRequest(path: path, cwd: cwd, command: command, quarantined: quarantined)
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-open-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return URL(fileURLWithPath: folder.path, isDirectory: true)
    }

    struct AttributeWriteFailed: Error {
        var code: Int32
    }

    /// A file in `folder`; `quarantined` marks it as a browser download does.
    static func file(_ name: String, in folder: URL, quarantined: Bool = false) throws -> URL {
        let file = URL(fileURLWithPath: (folder.path as NSString).appendingPathComponent(name))
        try Data("echo hi\n".utf8).write(to: file)
        if quarantined {
            let value = Array("0083;6720a7c0;Safari;".utf8)
            let status = value.withUnsafeBytes { setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            guard status == 0 else { throw AttributeWriteFailed(code: errno) }
        }
        return file
    }
}
