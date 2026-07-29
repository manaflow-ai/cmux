import Darwin
import Foundation
@testable import CmuxRemoteSession

struct MarkerGatedFailingRemoteProcessStdinWriter: RemoteProcessStdinWriting {
    enum Gate: Equatable, Sendable {
        case launched
        case exited
    }

    let markerURL: URL
    let gate: Gate

    func write(
        _ data: Data,
        to handle: FileHandle,
        stopFileDescriptor: Int32
    ) throws {
        let processIdentifier = try waitForProcessMarker()
        if gate == .exited, !waitForProcessExit(processIdentifier) {
            throw POSIXError(.ETIMEDOUT)
        }
        throw POSIXError(.EIO)
    }

    private func waitForProcessMarker() throws -> pid_t {
        let deadline = DispatchTime.now() + 2
        repeat {
            if let contents = try? String(contentsOf: markerURL, encoding: .utf8),
               let processIdentifier = pid_t(
                   contents.trimmingCharacters(in: .whitespacesAndNewlines)
               ) {
                return processIdentifier
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while DispatchTime.now() < deadline
        throw POSIXError(.ETIMEDOUT)
    }

    private func waitForProcessExit(_ processIdentifier: pid_t) -> Bool {
        let deadline = DispatchTime.now() + 2
        repeat {
            errno = 0
            if kill(processIdentifier, 0) == -1, errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while DispatchTime.now() < deadline
        return false
    }
}
