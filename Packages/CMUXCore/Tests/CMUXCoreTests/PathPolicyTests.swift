import CMUXCore
import XCTest

final class PathPolicyTests: XCTestCase {
    func testLinuxUsesXDGDirectoriesWhenPresent() throws {
        let paths = try CMUXPathPolicy.resolve(
            platform: .linux,
            environment: CMUXPathEnvironment(
                homeDirectory: "/home/user",
                xdgConfigHome: "/xdg/config",
                xdgStateHome: "/xdg/state",
                xdgRuntimeDirectory: "/run/user/1000"
            )
        )

        XCTAssertEqual(paths.configDirectory, "/xdg/config/cmux")
        XCTAssertEqual(paths.stateDirectory, "/xdg/state/cmux")
        XCTAssertEqual(paths.socketDirectory, "/run/user/1000/cmux")
        XCTAssertEqual(paths.socketFilePath, "/run/user/1000/cmux/cmux.sock")
    }

    func testLinuxFallsBackToHomeXDGDefaults() throws {
        let paths = try CMUXPathPolicy.resolve(
            platform: .linux,
            environment: CMUXPathEnvironment(homeDirectory: "/home/user")
        )

        XCTAssertEqual(paths.configDirectory, "/home/user/.config/cmux")
        XCTAssertEqual(paths.stateDirectory, "/home/user/.local/state/cmux")
        XCTAssertEqual(paths.socketDirectory, "/tmp/cmux")
        XCTAssertEqual(paths.socketFilePath, "/tmp/cmux/cmux.sock")
    }

    func testMacOSUsesApplicationSupportWhenPresent() throws {
        let paths = try CMUXPathPolicy.resolve(
            platform: .macOS,
            environment: CMUXPathEnvironment(
                homeDirectory: "/Users/user",
                macOSApplicationSupportDirectory: "/Users/user/Library/Application Support"
            )
        )

        XCTAssertEqual(paths.configDirectory, "/Users/user/Library/Application Support/cmux")
        XCTAssertEqual(paths.stateDirectory, "/Users/user/Library/Application Support/cmux")
        XCTAssertEqual(paths.socketDirectory, "/Users/user/Library/Application Support/cmux")
        XCTAssertEqual(paths.socketFilePath, "/Users/user/Library/Application Support/cmux/cmux.sock")
    }

    func testRejectsEmptyHomeDirectory() throws {
        XCTAssertThrowsError(
            try CMUXPathPolicy.resolve(
                platform: .linux,
                environment: CMUXPathEnvironment(homeDirectory: "")
            )
        )
    }
}
