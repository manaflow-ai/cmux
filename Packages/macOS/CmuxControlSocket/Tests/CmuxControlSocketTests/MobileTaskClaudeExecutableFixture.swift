import Foundation

/// Owns fake executables and a login shell isolated from the user's CLI setup.
struct MobileTaskClaudeExecutableFixture {
    let directory: URL
    let shell: URL
    let defaultExecutable: URL

    init(shellPath: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-task-claude-\(UUID().uuidString)", isDirectory: true)
        shell = directory.appendingPathComponent("login-shell")
        defaultExecutable = directory.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flags = shellPath == "/bin/bash" ? "--noprofile --norc" : "-f"
        try Self.writeExecutable("""
        #!/bin/sh
        export HOME=\(Self.quote(directory.path))
        export ZDOTDIR=\(Self.quote(directory.path))
        export PATH=\(Self.quote(directory.path))
        exec \(shellPath) \(flags) "$@"
        """, to: shell)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func executable(named name: String, modelID: String, exitCode: Int = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let response = """
        {"type":"control_response","response":{"subtype":"success","request_id":"cmux-list-options","response":{"models":[{"value":"\(modelID)","displayName":"Fixture model"}]}}}
        """
        try Self.writeExecutable("""
        #!/bin/sh
        IFS= read -r request
        printf '%s' "$request" > \(Self.quote(url.path + ".request"))
        printf '%s\\n' "$@" > \(Self.quote(url.path + ".arguments"))
        printf '%s' "$CLAUDE_CODE_ENTRYPOINT" > \(Self.quote(url.path + ".entrypoint"))
        printf '%s\\n' \(Self.quote(response))
        exit \(exitCode)
        """, to: url)
        return url
    }

    func recorded(_ suffix: String, for executable: URL) throws -> String {
        try String(contentsOfFile: executable.path + "." + suffix, encoding: .utf8)
    }

    func clearRecordings(for executable: URL) throws {
        for suffix in ["request", "arguments", "entrypoint"] {
            try FileManager.default.removeItem(atPath: executable.path + "." + suffix)
        }
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
