import Foundation

@testable import CmuxNextAgentPane

/// A disposable shell home and working directory; no completion test inherits host settings.
struct ShellCompletionFixture {
    let directory: URL
    let shell: String

    init(shell: String, files: [String] = [], directories: [String] = []) throws {
        self.shell = shell
        directory = FileManager.default.temporaryDirectory
            .appending(path: "complete-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for name in directories {
                try FileManager.default.createDirectory(at: directory.appending(path: name), withIntermediateDirectories: true)
            }
            for name in files + [".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile", ".zshenv"] {
                try Data().write(to: directory.appending(path: name))
            }
        } catch {
            remove()
            throw error
        }
    }

    var cwd: String { directory.path }

    var completion: AgentPaneShellCompletion {
        AgentPaneShellCompletion(
            shell: "/bin/\(shell)",
            environment: ["HOME": cwd, "ZDOTDIR": cwd, "HISTFILE": "\(cwd)/history",
                          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "TERM": "xterm"],
            home: cwd,
            timeout: .seconds(60)
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
