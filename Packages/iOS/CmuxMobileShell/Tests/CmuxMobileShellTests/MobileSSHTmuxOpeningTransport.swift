@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation

/// Acknowledges tmux commands so teardown does not depend on a live server.
final class MobileSSHTmuxOpeningTransport: MobileSSHTmuxControlTransport {
    let events: AsyncStream<SSHSessionEvent>
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
    }

    func write(_ data: Data) async throws {
        for _ in data.split(separator: 10) {
            continuation.yield(.stdout(Data("%begin 1 1 1\n%end 1 1 1\n".utf8)))
        }
    }

    func close() async {
        continuation.yield(.closed)
        continuation.finish()
    }
}
