@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation

/// Acknowledges tmux commands so teardown does not depend on a live server.
final class MobileSSHTmuxOpeningTransport: MobileSSHTmuxControlTransport {
    let events: AsyncStream<SSHSessionEvent>
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation
    let writes: AsyncStream<Data>
    private let writesContinuation: AsyncStream<Data>.Continuation
    private let respondToWrites: Bool

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
        continuation.yield(.closed)
        continuation.finish()
        writesContinuation.finish()
    }

    func abort(afterWriting data: Data) {
        writesContinuation.yield(data)
        continuation.yield(.closed)
        continuation.finish()
        writesContinuation.finish()
    }
}
