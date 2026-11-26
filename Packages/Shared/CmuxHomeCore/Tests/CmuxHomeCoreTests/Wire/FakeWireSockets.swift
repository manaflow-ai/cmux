import Foundation
import os
@testable import CmuxHomeCore

/// Hands out ``FakeWireSocket``s and remembers each, in dial order.
final class FakeWireSockets: HomeWireSocketConnecting {
    // A test fake: the lock guards the list of dialed sockets the test reads synchronously.
    private let state = OSAllocatedUnfairLock(uncheckedState: [FakeWireSocket]())

    var all: [FakeWireSocket] { state.withLockUnchecked { $0 } }

    /// The sockets dialed to `path` (`/v1/wire/user`, `/v1/wire/conv/<id>`).
    func dialed(_ path: String) -> [FakeWireSocket] {
        all.filter { $0.request.url?.path == path }
    }

    func connect(_ request: URLRequest) -> any HomeWireSocket {
        let socket = FakeWireSocket(request: request)
        state.withLockUnchecked { $0.append(socket) }
        return socket
    }
}
