import CmuxNextAgentPane
import Foundation
import Testing

/// With no acpmux socket, ``AcpmuxPersonLine/open(_:deadline:)`` answers nil from the connect
/// itself (it fails at once on the line's queue): no stat on the main actor first, and no wait
/// for the connection's deadline.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct AcpmuxPersonLineMissingSocketTests {
    @Test func aMissingSocketOpensNothingBeforeTheDeadline() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-person-\(UUID().uuidString.prefix(8))")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [],
                                            childEnvironment: [:])
        let clock = ContinuousClock()
        let started = clock.now
        let line = await AcpmuxPersonLine.open(environment, deadline: .seconds(30))
        #expect(line == nil)
        let elapsed = clock.now - started
        #expect(elapsed < .seconds(10), "a missing socket answered after \(elapsed)")
    }
}
