@testable import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// A host that takes only a staged file's bytes (`putFile(sessionId:name:data:)`) still takes a staged file: the
/// protocol's default reads it on the runner's files lane (never the cooperative pool) and puts its bytes
/// (p02-threads 047-052). Before, a host without its own file put refused every staged upload.
@Suite(.timeLimit(.minutes(1))) struct AgentPaneHostFilePutFallbackTests {
    /// A host that records the bytes it was given.
    private nonisolated final class BytesHost: AgentPaneHostProviding, Sendable {
        let received = Mutex<[Data]>([])

        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }

        func putFile(sessionId: String, name: String, data: Data) async throws -> String {
            received.withLock { $0.append(data) }
            return "/remote/" + name
        }
    }

    @Test func aStagedFileReachesAHostThatTakesOnlyBytes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-put-fallback-\(UUID().uuidString)")
        try Data("staged".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let host = BytesHost()

        let path = try await host.putFile(sessionId: "s1", name: "a.txt", file: file, runner: BackgroundWork(label: "test.put-fallback"))

        #expect(path == "/remote/a.txt")
        #expect(host.received.withLock { $0 } == [Data("staged".utf8)])
    }
}
