import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH locale environment")
struct SSHLocaleEnvironmentTests {
    @Test("process and persisted shell launchers remove only the macOS shorthand", arguments: [
        nil, "", "UTF-8", "UTF8", "utf-8", "C", "C.UTF-8", "en_US.UTF-8", "de_DE.UTF-8"
    ] as [String?])
    func processAndShellAgree(ctype: String?) throws {
        let policy = SSHLocaleEnvironment()
        var inherited = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "LC_MESSAGES": "de_DE.UTF-8",
            "SSH_AUTH_SOCK": "/tmp/test-agent.sock"
        ]
        inherited["LC_CTYPE"] = ctype
        var expected = inherited
        if ctype == "UTF-8" { expected.removeValue(forKey: "LC_CTYPE") }
        #expect(policy.sanitized(inherited) == expected)

        // Inspect the actual child environment, not just the generated script.
        let result = try run(
            script: policy.shellSetup + "\nexec /usr/bin/env",
            environment: inherited
        )
        #expect(result.status == 0)
        let observed = Dictionary(uniqueKeysWithValues: result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil as (String, String)? }
            return (String(parts[0]), String(parts[1]))
        })
        for key in ["LC_CTYPE", "LANG", "LC_ALL", "LC_MESSAGES", "SSH_AUTH_SOCK"] {
            #expect(observed[key] == expected[key])
        }
    }

    @Test("the SSH wrapper preserves argument boundaries, exit status, and the parent's locale")
    func childWrapper() throws {
        let command = SSHLocaleEnvironment().shellCommandPrefix(arguments: [
            "/bin/sh", "-c", "printf '%s\\n' \"${LC_CTYPE-unset}\" \"$@\"; exit 23", "ssh",
            "SetEnv=LC_CTYPE=fr_FR.UTF-8", "space arg", "quote'arg"
        ])
        let result = try run(
            script: command + " appended; result=$?; printf '%s\\n' \"$result\" \"$LC_CTYPE\"",
            environment: ["LC_CTYPE": "UTF-8"]
        )
        #expect(result.status == 0)
        #expect(result.stdout == "unset\nSetEnv=LC_CTYPE=fr_FR.UTF-8\nspace arg\nquote'arg\nappended\n23\nUTF-8\n")
    }

    private func run(script: String, environment: [String: String]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = environment
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
