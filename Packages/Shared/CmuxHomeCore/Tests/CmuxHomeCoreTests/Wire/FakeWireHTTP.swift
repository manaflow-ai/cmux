import Foundation
import os
@testable import CmuxHomeCore

/// A scripted `cmux.wire/1` server for `WireHomeSource` tests: records every
/// request and answers with `handler` (path, JSON body) or the default
/// routes below.
final class FakeWireHTTP: HomeWireHTTP {
    typealias Handler = @Sendable (_ path: String, _ body: HomeWireJSON) throws -> HomeWireHTTPReply?

    private struct State {
        var requests: [URLRequest] = []
        var handler: Handler?
        var opRev: UInt64 = 10
    }

    // A test fake: the lock guards the recorded requests that the test reads synchronously.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(_ handler: Handler? = nil) {
        state.withLockUnchecked { $0.handler = handler }
    }

    /// Replaces the script (nil: default routes only).
    func script(_ handler: Handler?) {
        state.withLockUnchecked { $0.handler = handler }
    }

    var requests: [URLRequest] { state.withLockUnchecked { $0.requests } }

    /// The JSON bodies of the requests to `path`, in order.
    func bodies(_ path: String) -> [HomeWireJSON] {
        requests.filter { $0.url?.path == path }.map { HomeWireJSON.parse($0.httpBody ?? Data()) ?? .null }
    }

    /// The `POST /v1/ops` bodies whose op is `op`.
    func ops(_ op: String) -> [HomeWireJSON] {
        bodies("/v1/ops").filter { $0["op"].string == op }
    }

    func send(_ request: URLRequest) async throws -> HomeWireHTTPReply {
        let body = HomeWireJSON.parse(request.httpBody ?? Data()) ?? .null
        let path = request.url?.path ?? ""
        let handler = state.withLockUnchecked { state -> Handler? in
            state.requests.append(request)
            return state.handler
        }
        if let handler, let reply = try handler(path, body) { return reply }
        return defaultReply(path, body)
    }

    private func defaultReply(_ path: String, _ body: HomeWireJSON) -> HomeWireHTTPReply {
        switch (path, body["op"].string) {
        case ("/v1/selfhost/info", _):
            return HomeWireHTTPReply(json: ["kind": "selfhost", "user_id": .string(WireFixture.me), "login": "me@example.com",
                                            "display_name": "Me", "server_name": "mini"])
        case ("/v1/read", "inbox.list"?):
            return HomeWireHTTPReply(json: ["ok": true, "value": ["entries": [WireFixture.entry()]], "revision": "1"])
        case ("/v1/read", "conversation.snapshot"?):
            return HomeWireHTTPReply(json: ["ok": true, "value": WireFixture.snapshot(seq: 3, rev: 3, messages: [WireFixture.message(seq: 1)])])
        case ("/v1/read", _):
            return HomeWireHTTPReply(json: ["ok": true, "value": [:]])
        case ("/v1/ops", _):
            let rev = state.withLockUnchecked { state -> UInt64 in
                state.opRev += 1
                return state.opRev
            }
            return HomeWireHTTPReply(json: ["ok": true, "value": ["rev": .uint(rev)], "replayed": false])
        default:
            return HomeWireHTTPReply(status: 404, json: ["ok": false, "error": ["code": "not_found"]])
        }
    }
}
