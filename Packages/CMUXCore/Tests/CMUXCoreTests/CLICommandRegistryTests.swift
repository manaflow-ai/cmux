import CMUXCore
import XCTest

final class CLICommandRegistryTests: XCTestCase {
    func testCanonicalNameAcceptsKnownCommandsCaseInsensitively() throws {
        XCTAssertEqual(CLICommandRegistry.canonicalName(for: "PING"), "ping")
        XCTAssertEqual(CLICommandRegistry.canonicalName(for: "Browser"), "browser")
        XCTAssertEqual(CLICommandRegistry.canonicalName(for: "rename-window"), "rename-window")
        XCTAssertEqual(CLICommandRegistry.canonicalName(for: "__TMUX-COMPAT"), "__tmux-compat")
    }

    func testCanonicalNameRejectsUnknownCommandsAndPaths() throws {
        XCTAssertNil(CLICommandRegistry.canonicalName(for: ""))
        XCTAssertNil(CLICommandRegistry.canonicalName(for: "not-a-command"))
        XCTAssertNil(CLICommandRegistry.canonicalName(for: "./project"))
        XCTAssertNil(CLICommandRegistry.canonicalName(for: "/tmp/project"))
    }

    func testDescriptorsExposePlatformNeutralRouting() throws {
        XCTAssertEqual(CLICommandRegistry.descriptor(for: "ping")?.route, .defaultSocket)
        XCTAssertEqual(CLICommandRegistry.descriptor(for: "welcome")?.route, .local)
        XCTAssertEqual(CLICommandRegistry.descriptor(for: "remote-daemon-status")?.route, .local)
        XCTAssertEqual(CLICommandRegistry.descriptor(for: "capture-pane")?.route, .defaultSocket)
    }

    func testRegistryContainsCompatibilityAndAgentCommands() throws {
        XCTAssertTrue(CLICommandRegistry.contains("claude-hook"))
        XCTAssertTrue(CLICommandRegistry.contains("codex"))
        XCTAssertTrue(CLICommandRegistry.contains("opencode-hook"))
        XCTAssertTrue(CLICommandRegistry.contains("browser-back"))
        XCTAssertTrue(CLICommandRegistry.contains("markdown"))
    }
}
