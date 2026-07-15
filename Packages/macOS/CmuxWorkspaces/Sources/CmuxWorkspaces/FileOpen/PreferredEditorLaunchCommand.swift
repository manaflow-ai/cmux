import Foundation

/// A shell command rendered for one preferred-editor file open.
///
/// Source locations are emitted only for editor CLIs whose argument contract
/// is known. Unknown commands receive the plain file path so cmux never asks
/// an editor to open a nonexistent colon-suffixed filename.
nonisolated struct PreferredEditorLaunchCommand: Equatable, Sendable {
    let command: String
    private let executableName: String?

    init(command: String) {
        self.command = command
        executableName = preferredEditorExecutableName(command: command)
    }

    var supportsSourceLocation: Bool {
        guard let executableName else { return false }
        return [
            "code", "code-insiders", "codium", "cursor", "subl", "zed", "zed-preview",
        ].contains(executableName)
    }

    func shellCommand(url: URL, line: Int?, column: Int?) -> String {
        let path = url.path
        let arguments: [String]
        if let line, supportsSourceLocation {
            let location = column.map { "\(path):\(line):\($0)" } ?? "\(path):\(line)"
            if usesGotoFlag {
                arguments = hasGotoFlag
                    ? [location]
                    : ["--goto", location]
            } else {
                arguments = [location]
            }
        } else {
            arguments = [path]
        }

        return ([command] + arguments.map(\.posixShellSingleQuoted))
            .joined(separator: " ")
    }

    private var usesGotoFlag: Bool {
        guard let executableName else { return false }
        return ["code", "code-insiders", "codium", "cursor"].contains(executableName)
    }

    private var hasGotoFlag: Bool {
        command.split(whereSeparator: \Character.isWhitespace).contains { token in
            token == "-g" || token == "--goto"
        }
    }
}

private func preferredEditorExecutableName(command: String) -> String? {
    for rawToken in command.split(whereSeparator: \Character.isWhitespace) {
        let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !token.isEmpty else { continue }
        let name = (token as NSString).lastPathComponent.lowercased()
        if name == "env" || (!token.contains("/") && token.contains("=")) {
            continue
        }
        return name
    }
    return nil
}
