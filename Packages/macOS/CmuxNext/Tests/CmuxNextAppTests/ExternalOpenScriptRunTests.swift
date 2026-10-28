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
