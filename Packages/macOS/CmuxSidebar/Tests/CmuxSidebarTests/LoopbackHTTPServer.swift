import Foundation
import Network

/// A minimal loopback HTTP server whose response body can be changed between requests.
///
/// Reload correctness cannot be shown by counting issued loads: the interesting failure is a load
/// that *is* issued and comes back from the URL cache, which looks identical from the host's side
/// and leaves the user staring at the same stale page they ran `cmux sidebar reload` to replace.
/// Only a server that has changed its bytes can tell those apart, so the test needs one.
///
/// Deliberately not a real HTTP implementation: it answers any request line with the current body
/// and closes. It does send a long `Cache-Control: max-age`, which is the case that actually
/// matters: a sidebar served by a local dev server that declares its assets cacheable is a page a
/// default-policy load is entitled to satisfy from cache without asking the server anything.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.tests.loopback-http")
    private let lock = NSLock()
    private var _body: String
    private var _requestCount = 0

    /// The body served to the next request.
    var body: String {
        get { lock.withLock { _body } }
        set { lock.withLock { _body = newValue } }
    }

    /// How many requests have been answered so far.
    var requestCount: Int { lock.withLock { _requestCount } }

    /// The origin the server is listening on, once started.
    private(set) var origin: URL?

    private let maxAge: Int

    /// Creates a server that is not yet listening.
    ///
    /// Throws rather than trapping when the listener cannot be created. A test host that has run out
    /// of sockets is a condition worth reading in the failure message; `try!` turns it into a crash
    /// that takes the whole suite with it and says nothing about why.
    ///
    /// - Parameters:
    ///   - body: The initial response body.
    ///   - maxAge: The `Cache-Control: max-age` seconds to advertise.
    init(body: String, maxAge: Int = 3600) throws {
        _body = body
        self.maxAge = maxAge
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Creates a started server and its origin in one step.
    ///
    /// The common case: a test wants a live origin on a port nothing else on the machine owns, and
    /// has nothing to say about a server that failed to come up beyond reporting it.
    ///
    /// - Parameters:
    ///   - body: The initial response body.
    ///   - maxAge: The `Cache-Control: max-age` seconds to advertise.
    static func started(body: String, maxAge: Int = 3600) throws -> (LoopbackHTTPServer, URL) {
        let server = try LoopbackHTTPServer(body: body, maxAge: maxAge)
        guard let origin = server.start() else {
            server.stop()
            throw StartFailure()
        }
        return (server, origin)
    }

    /// The listener came up but never reported a port.
    struct StartFailure: Error, CustomStringConvertible {
        var description: String { "loopback HTTP server did not resolve a port" }
    }

    /// Starts listening and resolves the origin. Returns `nil` if the port never materialises.
    func start(timeout: TimeInterval = 5) -> URL? {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = listener.port?.rawValue, port != 0 {
                let url = URL(string: "http://127.0.0.1:\(port)/")
                origin = url
                return url
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let payload = lock.withLock { () -> String in
                _requestCount += 1
                return _body
            }
            let bytes = Array(payload.utf8)
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Cache-Control: max-age=\(maxAge)\r
            Content-Length: \(bytes.count)\r
            Connection: close\r
            \r

            """
            var data = Data(response.utf8)
            data.append(contentsOf: bytes)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
