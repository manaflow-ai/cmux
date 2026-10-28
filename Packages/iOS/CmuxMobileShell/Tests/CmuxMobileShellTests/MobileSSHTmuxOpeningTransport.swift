@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation

/// Acknowledges tmux commands so teardown does not depend on a live server.
/// Test transport is only accessed from the MainActor test suite; the
/// unchecked conformance preserves the protocol's cross-task test seam.
final class MobileSSHTmuxOpeningTransport: MobileSSHTmuxControlTransport, @unchecked Sendable {
    let events: AsyncStream<SSHSessionEvent>
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation
    let writes: AsyncStream<Data>
    private let writesContinuation: AsyncStream<Data>.Continuation
    private let respondToWrites: Bool
    private(set) var didAbort = false

    init(respondToWrites: Bool = true) {
        (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
        (writes, writesContinuation) = AsyncStream.makeStream(of: Data.self)
        self.respondToWrites = respondToWrites
    }

    func write(_ data: Data) async throws {
        writesContinuation.yield(data)
        if respondToWrites {
            for _ in data.split(separator: 10) {
                continuation.yield(.stdout(Data("%begin 1 1 1\n%end 1 1 1\n".utf8)))
            }
        }
    }

    func close() async {
        continuation.yield(.closed)
        continuation.finish()
        writesContinuation.finish()
    }

    func abort() {
        didAbort = true
        continuation.yield(.closed)
        continuation.finish()
        writesContinuation.finish()
    }

    func abort(afterWriting data: Data) {
        didAbort = true
        writesContinuation.yield(data)
        continuation.yield(.closed)
        continuation.finish()
        writesContinuation.finish()
    }
}
