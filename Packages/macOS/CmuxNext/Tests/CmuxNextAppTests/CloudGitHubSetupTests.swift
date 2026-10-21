import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Set Up GitHub on This Machine (`cmux cloud setup-github --target machine:<id>`): the git
/// identity from this Mac reaches the machine as data, never as shell code; a non-person run must
/// name its machine; and the result carries only the agreed keys, never a token.
@MainActor @Suite(.serialized)
struct CloudGitHubSetupTests {
    /// Names a person could have, and names written to break out of a shell string.
    nonisolated static let hostileValues = [
        "O'Brien; rm -rf ~",
        "O'Brien'; touch \"$PWNED\"; echo '",
        "$(touch \"$PWNED\")",
        "`touch \"$PWNED\"`",
        "a\" ; touch \"$PWNED\" ; \"",
        "back\\slash \\' and \\\\",
        "José Ñúñez 李雷 🚀",
        "${PWNED:+x} $HOME * ? [a] ~ & | < > ;",
    ]

    // MARK: Quoting

    /// The identity line, run by a real `/bin/sh` against a scratch HOME, writes each hostile value
    /// to git config byte for byte, and none of them runs a command.
    @Test(arguments: hostileValues)
    func theIdentityLineSetsTheValueAndRunsNothing(value: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cn-gh-setup-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let pwned = home.appendingPathComponent("pwned").path
        let identity = CloudGitHubSetup.GitIdentity(name: value, email: value)
        let ran = try Self.sh(CloudGitHubSetup.identityCommand(identity), home: home.path, extra: ["PWNED": pwned])
        #expect(ran.status == 0)
        #expect(ran.output == "cmux-git: set\n")
        #expect(!FileManager.default.fileExists(atPath: pwned), "a value ran as a command")
        let config = home.appendingPathComponent(".gitconfig").path
        #expect(try Self.git(["config", "--file", config, "--get", "user.name"]) == value)
        #expect(try Self.git(["config", "--file", config, "--get", "user.email"]) == value)
    }

    @Test(arguments: hostileValues)
    func aQuotedValueIsOneShellWordWithTheSameBytes(value: String) throws {
        let ran = try Self.sh("printf '%s|' \(CloudGitHubSetup.shellQuote(value))", home: NSTemporaryDirectory(), extra: ["PWNED": "/nonexistent/x"])
        #expect(ran.output == value + "|")
    }

    @Test func aQuoteClosesEscapesAndReopens() {
        #expect(CloudGitHubSetup.shellQuote("O'Brien; rm -rf /") == #"'O'\''Brien; rm -rf /'"#)
    }

    @Test func theFullCommandHoldsTheValuesOnlyQuoted() {
        let command = CloudGitHubSetup.command(.init(name: "O'Brien; rm -rf ~", email: "o@example.com"))
        #expect(command.contains(#"git config --global user.name 'O'\''Brien; rm -rf ~'"#))
        #expect(command.contains("git config --global user.email 'o@example.com'"))
        #expect(!command.contains("O'Brien;"), "the name appears unquoted")
    }

    @Test func noIdentitySkipsGitConfig() {
        let command = CloudGitHubSetup.command(.init(name: nil, email: nil))
        #expect(command.contains("echo 'cmux-git: skipped'"))
        #expect(!command.contains("git config"))
    }

    // MARK: Validation

    @Test(arguments: ["Ann\nrm -rf ~", "Ann\0", "Ann\u{1B}[31m", "Ann\r", "Ann\u{7F}", String(repeating: "a", count: 257)])
    func aValueWithAControlCharacterOrTooLongIsRefused(value: String) {
        #expect(throws: ActionFailure(message: CloudStrings.gitHubIdentityUnsafe)) {
            try CloudGitHubSetup.validated(.init(name: value, email: "a@b.c"))
        }
    }

    @Test func gitsTrailingNewlineIsTrimmedAndEmptyIsUnset() throws {
        let identity = try CloudGitHubSetup.validated(.init(name: "Ann Lee\n", email: "\n"))
        #expect(identity == .init(name: "Ann Lee", email: nil))
    }

    @Test func theLocalIdentityIsReadFromGlobalGitConfig() async {
        let identity = await CloudGitHubSetup.localIdentity(git: FakeGit(values: ["user.name": "Ann Lee\n"]), home: "/Users/ann")
        #expect(identity == .init(name: "Ann Lee\n", email: nil))
    }

    // MARK: Results

    @Test func aPendingSignInAnswersWithTheCodeAndGitHubsPage() {
        let identity = CloudGitHubSetup.GitIdentity(name: "Ann Lee", email: "ann@example.com")
        let outcome = CloudGitHubSetup.parse(exitCode: 0, stdout: "cmux-git: set\ncmux-gh: pending AB12-CD34\n")
        #expect(outcome == .init(identity: .set, gitHub: .pending, deviceCode: "AB12-CD34"))
        let fields = CloudGitHubSetup.fields(outcome, identity: identity)
        #expect(fields == [
            "ok": .bool(true), "user_name": .string("Ann Lee"), "user_email": .string("ann@example.com"),
            "gh_status": .string("pending"), "device_code": .string("AB12-CD34"),
            "verification_uri": .string("https://github.com/login/device"),
        ])
    }

    @Test func theResultCarriesOnlyTheAgreedKeys() {
        let allowed: Set<String> = ["ok", "user_name", "user_email", "gh_status", "device_code", "verification_uri"]
        let identity = CloudGitHubSetup.GitIdentity(name: "Ann", email: "a@b.c")
        for stdout in ["cmux-git: set\ncmux-gh: logged_in", "cmux-git: skipped\ncmux-gh: missing", "cmux-git: failed\ncmux-gh: failed",
                       "cmux-git: set\ncmux-gh: pending AB12-CD34", "gho_secret_token\ncmux-gh: pending gho_secret_token"] {
            let fields = CloudGitHubSetup.fields(CloudGitHubSetup.parse(exitCode: 0, stdout: stdout), identity: identity)
            #expect(Set(fields.keys).isSubset(of: allowed))
            #expect(!fields.values.contains(.string("gho_secret_token")))
        }
    }

    @Test func alreadySignedInIsOkWithNoCode() {
        let outcome = CloudGitHubSetup.parse(exitCode: 0, stdout: "cmux-git: set\ncmux-gh: logged_in\n")
        #expect(outcome.ok)
        #expect(outcome.deviceCode == nil)
        #expect(CloudGitHubSetup.fields(outcome, identity: .init(name: "A", email: nil))["device_code"] == nil)
    }

    @Test func aMissingGhIsNotOk() {
        let outcome = CloudGitHubSetup.parse(exitCode: 0, stdout: "cmux-git: set\ncmux-gh: missing\n")
        #expect(!outcome.ok)
        #expect(CloudGitHubSetup.fields(outcome, identity: .init())["gh_status"] == .string("missing"))
    }

    @Test(arguments: ["cmux-gh: pending", "cmux-gh: pending abcd-1234", "cmux-gh: pending AB12CD34", "cmux-gh: pending https://evil.example/AB12-CD34"])
    func aCodeNotInGitHubsShapeIsAFailure(line: String) {
        let outcome = CloudGitHubSetup.parse(exitCode: 0, stdout: "cmux-git: set\n" + line)
        #expect(outcome.gitHub == .failed)
        #expect(outcome.deviceCode == nil)
    }

    @Test func aFailedExecIsAFailure() {
        let outcome = CloudGitHubSetup.parse(exitCode: 124, stdout: "cmux-git: set\ncmux-gh: pending AB12-CD34\n")
        #expect(outcome == .init(identity: .set, gitHub: .failed, deviceCode: nil))
        #expect(!outcome.ok)
    }

    @Test func identityNotSetLeavesTheNameOutOfTheResult() {
        let outcome = CloudGitHubSetup.parse(exitCode: 0, stdout: "cmux-git: failed\ncmux-gh: logged_in\n")
        let fields = CloudGitHubSetup.fields(outcome, identity: .init(name: "Ann", email: "a@b.c"))
        #expect(fields["ok"] == .bool(false))
        #expect(fields["user_name"] == nil)
    }

    // MARK: Target

    /// A CLI, MCP, script, page or remote run with no `--target machine:<id>` is refused, even with
    /// one Cloud machine (#23155): the action never picks the machine the person's window shows.
    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRunThatIsNotThePersonsNeedsAMachineTarget(origin: ActionOrigin) {
        let f = CloudCLITargetTests.fixture()
        let registry = ActionRegistry(catalog: f.services.registry.descriptors)
        CloudHandlers.bindGitHubSetup(into: registry, context: f.context, reason: { nil })
        #expect(f.services.machines.cloud.count == 1)
        let refusal = registry.capturingRefusal {
            _ = registry.perform("cloudSetupGitHub", invocation: ActionInvocation(origin: origin))
        }
        #expect(refusal == CloudStrings.noMachine)
    }

    @Test func theActionIsACLIVerbOnAMachineThatAnswersWithItsResult() throws {
        let descriptor = try #require(ActionRegistry(catalog: CloudCLITargetTests.fixture().services.registry.descriptors)
            .descriptor(for: "cloudSetupGitHub"))
        #expect(descriptor.cliName == "cloud setup-github")
        #expect(descriptor.targets == [.machine])
        #expect(descriptor.waitsForResult)
    }

    // MARK: Helpers

    nonisolated struct FakeGit: MarkdownGitRunning {
        var values: [String: String]
        func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
            guard arguments.prefix(3) == ["config", "--global", "--get"], let key = arguments.last, let value = values[key] else {
                return MarkdownGitOutput(status: 1, output: "")
            }
            return MarkdownGitOutput(status: 0, output: value)
        }
    }

    static func sh(_ script: String, home: String, extra: [String: String]) throws -> (status: Int32, output: String) {
        try run("/bin/sh", ["-c", script], environment: [
            "HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C",
        ].merging(extra) { _, new in new })
    }

    static func git(_ arguments: [String]) throws -> String {
        let ran = try run("/usr/bin/git", arguments, environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"])
        return String(ran.output.dropLast())
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
