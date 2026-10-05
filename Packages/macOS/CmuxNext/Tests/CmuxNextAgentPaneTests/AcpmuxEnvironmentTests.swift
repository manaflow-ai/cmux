import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AcpmuxEnvironmentTests {
    private let userHome = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let bundled = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin", isDirectory: true)

    private func resolve(tag: String?, environment: [String: String] = [:], executables: Set<String>) -> AcpmuxEnvironment? {
        AcpmuxEnvironment.resolve(
            tag: tag, bundledBinDirectory: bundled, environment: environment, userHome: userHome,
            uid: 501, isExecutable: { executables.contains($0) }
        )
    }

    @Test func prefersTheBundledBinaryThenPath() {
        let both: Set = ["/Applications/cmux.app/Contents/Resources/bin/acpmux", "/opt/tools/acpmux"]
        #expect(resolve(tag: nil, environment: ["PATH": "/opt/tools"], executables: both)?.executable.path == "/Applications/cmux.app/Contents/Resources/bin/acpmux")
        #expect(resolve(tag: nil, environment: ["PATH": "/opt/tools"], executables: ["/opt/tools/acpmux"])?.executable.path == "/opt/tools/acpmux")
        #expect(resolve(tag: nil, executables: ["/Users/someone/.cargo/bin/acpmux"])?.executable.path == "/Users/someone/.cargo/bin/acpmux")
        #expect(resolve(tag: nil, executables: []) == nil)
    }

    @Test func releaseSharesTheUsersDaemon() throws {
        let environment = try #require(resolve(tag: nil, executables: ["/usr/local/bin/acpmux"]))
        #expect(environment.home.path == "/Users/someone/.acpmux")
        #expect(environment.socketPath == "/Users/someone/.acpmux/acpmux.sock")
        #expect(environment.daemonArguments.isEmpty)
        #expect(environment.childEnvironment == ["ACPMUX_HOME": "/Users/someone/.acpmux", "ACPMUX_SOCKET": "/Users/someone/.acpmux/acpmux.sock"])
    }

    @Test func releaseHonoursTheUsersOverrides() throws {
        let environment = try #require(resolve(
            tag: nil, environment: ["ACPMUX_HOME": "/data/acpmux", "ACPMUX_SOCKET": "/tmp/mine.sock"], executables: ["/usr/local/bin/acpmux"]
        ))
        #expect(environment.home.path == "/data/acpmux")
        #expect(environment.socketPath == "/tmp/mine.sock")
        #expect(environment.childEnvironment["ACPMUX_HOME"] == "/data/acpmux")
    }

    /// A tagged build never shares a daemon, socket or port with the release
    /// app, and finds the same daemon as `cmux acp` in its terminals.
    @Test func aTaggedBuildUsesTheSameTagHomeAsCmuxAcp() throws {
        let environment = try #require(resolve(tag: "Feat_ACP.2", executables: ["/usr/local/bin/acpmux"]))
        #expect(environment.home.path == "/Users/someone/.acpmux/tags/feat-acp-2")
        #expect(environment.socketPath == "/Users/someone/.acpmux/tags/feat-acp-2/acpmux.sock")
        #expect(environment.daemonArguments == ["--listen", "127.0.0.1:0"])
        #expect(environment.childEnvironment["ACPMUX_HOME"] == environment.home.path)
        #expect(environment.logPath == "/Users/someone/.acpmux/tags/feat-acp-2/daemon.log")
    }

    /// cmux-tui `acp::sanitize_tag` cases.
    @Test func tagSlugsMatchCmuxTui() {
        #expect(AcpmuxEnvironment.tagSlug("Feat_ACP.2") == "feat-acp-2")
        #expect(AcpmuxEnvironment.tagSlug("--nx--agent--") == "nx-agent")
        #expect(AcpmuxEnvironment.tagSlug("--") == nil)
        #expect(AcpmuxEnvironment.tagSlug("") == nil)
        #expect(resolve(tag: "--", executables: ["/usr/local/bin/acpmux"])?.home.path == "/Users/someone/.acpmux")
    }

    /// Mirrors acpmux `config::socket_path()` so the app finds a daemon the CLI started.
    @Test func longHomesUseTheSameTmpSocketAsAcpmux() {
        let home = URL(fileURLWithPath: "/Users/someone/Library/Application Support/cmux-next/acpmux-a-rather-long-tag-name-for-tests", isDirectory: true)
        // Any home whose socket path reaches 96 bytes; the hash is computed from the path as acpmux does.
        #expect(AcpmuxEnvironment.defaultSocketPath(home: home, uid: 501) == "/tmp/acpmux-501/978cd91c92b64955.sock")
        #expect(AcpmuxEnvironment.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(AcpmuxEnvironment.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
    }

    @Test func aDevOriginIsAddedOnlyWhenThereIsOne() throws {
        let environment = try #require(resolve(tag: "dev", executables: ["/usr/local/bin/acpmux"]))
        #expect(environment.allowingDevOrigin(nil) == environment)
        #expect(environment.allowingDevOrigin("http://127.0.0.1:4176").daemonArguments
            == ["--listen", "127.0.0.1:0", "--allow-dev-origin", "http://127.0.0.1:4176"])
    }
}
