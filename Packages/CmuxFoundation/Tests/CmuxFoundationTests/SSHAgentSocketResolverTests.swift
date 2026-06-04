import XCTest
@testable import CmuxFoundation

final class SSHAgentSocketResolverTests: XCTestCase {
    func testNormalizedAgentSocketPathExpandsTildeAgainstResolverEnvironmentHome() {
        let resolver = SSHAgentSocketResolver(environment: [
            "HOME": "/tmp/cmux-test-home",
        ])

        XCTAssertEqual(
            resolver.normalizedAgentSocketPath("~/.ssh/agent.sock"),
            "/tmp/cmux-test-home/.ssh/agent.sock"
        )
        XCTAssertEqual(resolver.normalizedAgentSocketPath("~"), "/tmp/cmux-test-home")
    }
}
