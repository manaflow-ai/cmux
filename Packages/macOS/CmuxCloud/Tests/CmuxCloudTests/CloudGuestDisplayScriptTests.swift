import Foundation
import Testing
@testable import CmuxCloud

/// `CloudGuestDisplayScript` is main-actor isolated, so its tests run there too.
@MainActor
@Suite("Cloud guest display helper")
struct CloudGuestDisplayScriptTests {
    @Test("refreshes an already-installed helper before creating a display")
    func refreshesInstalledHelper() {
        let command = CloudGuestDisplayScript.command(action: "create")

        #expect(command.contains("candidate=\"$(mktemp \"$HOME/.cmux/cmux-display.XXXXXX\")\""))
        #expect(command.contains("cmp -s \"$candidate\" \"$path\""))
        #expect(command.contains("pkill -TERM -u \"$(id -u)\" -f \"$path serve\""))
        #expect(command.contains("service_ready=0"))
        #expect(command.contains("for attempt in $(seq 1 100)"))
        #expect(command.contains("[ \"$service_ready\" = 1 ] || exit 1"))
        #expect(command.contains("\"$path\" create"))
    }
}

/// VM exec runs as the work user since #16769, where `runuser` is refused
/// ("may not be used by non-root users") and every display request failed.
/// Runs the command's own shell with stub `id`, `runuser` and `env` to see
/// which path reaches the helper.
@MainActor
@Suite("Cloud guest display helper user")
struct CloudGuestDisplayScriptUserTests {
    @Test("reaches the helper as the work user and as root", arguments: ["1000", "0"])
    func reachesHelperForExecUser(uid: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-display-user-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls").path
        let stubs = [
            "id": "echo \(uid)",
            "runuser": "[ \"$(id)\" = 0 ] || { echo 'runuser: may not be used by non-root users' >&2; exit 1; }\necho runuser >> '\(log)'\nshift 3\n\"$@\"",
            "env": "echo \"env $1 $2 $3\" >> '\(log)'",
        ]
        for (name, body) in stubs {
            let path = directory.appendingPathComponent(name).path
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", CloudGuestDisplayScript.command(action: "list")]
        shell.environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
        try shell.run()
        shell.waitUntilExit()

        #expect(shell.terminationStatus == 0)
        let calls = try String(contentsOfFile: log, encoding: .utf8)
        let expected = uid == "0" ? "runuser\n" : ""
        #expect(calls == expected + "env HOME=/home/cmux USER=cmux /bin/bash\n")
    }
}
