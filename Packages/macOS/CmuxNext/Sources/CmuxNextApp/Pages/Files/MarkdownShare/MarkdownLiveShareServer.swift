import Foundation
import Network

/// The local live link (plans/cmux-next/markdown-omnibar-DESIGN.md section 4.1): a small HTTP
/// server on `127.0.0.1` that serves only the Markdown files the user shared, each under an
/// unguessable token, as an escaped HTML page that reloads itself when the file changes on disk
/// (Server-Sent Events from ``FileChangeWatch``, no polling). It starts on the first link and lives
/// until ``stop()`` or the app quits; links are never written anywhere.
///
/// Connections and the listener deliver their events on the main queue (event delivery only,
/// through `MainQueueNetworkEvents`), so all state stays on the main actor; a page's file read runs off
/// it.
final class MarkdownLiveShareServer {
    enum Failure: Error, Equatable {
        case listenerFailed(String)
    }

    private struct Share {
        let file: URL
        let name: String
        var watch: FileChangeWatch?
        var streams: [ObjectIdentifier: NWConnection] = [:]
    }

    private var listener: NWListener?
    private var port: UInt16?
    private var ready: [CheckedContinuation<UInt16, any Error>] = []
    private var shares: [String: Share] = [:]
    private var tokens: [String: String] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let renderer = MarkdownHTMLRenderer()
    private let network = MainQueueNetworkEvents()
    private let clock: any Clock<Duration>

    /// Largest request head accepted; a longer one is dropped.
    static let headLimit = 16 * 1024

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// The live link of `file`: the same link for the same file while the server runs.
    func link(for file: URL) async throws -> URL {
        let file = file.standardizedFileURL.resolvingSymlinksInPath()
        let port = try await start()
        let token: String
        if let existing = tokens[file.path] {
            token = existing
        } else {
            token = Self.newToken()
            tokens[file.path] = token
            var share = Share(file: file, name: file.lastPathComponent)
            share.watch = watch(file, token: token)
            shares[token] = share
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/md/\(token)/\(file.lastPathComponent)"
        guard let url = components.url else { throw Failure.listenerFailed("bad link") }
        return url
    }

    /// Ends every link and connection.
    func stop() {
        for share in shares.values {
            share.watch?.stop()
            share.streams.values.forEach { $0.cancel() }
        }
        shares = [:]
        tokens = [:]
        connections.values.forEach { $0.cancel() }
        connections = [:]
        listener?.cancel()
        listener = nil
        port = nil
        let waiting = ready
        ready = []
        waiting.forEach { $0.resume(throwing: Failure.listenerFailed("stopped")) }
    }

    // MARK: Listener

    private func start() async throws -> UInt16 {
        if let port { return port }
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            parameters.acceptLocalOnly = true
            let listener: NWListener
            do { listener = try NWListener(using: parameters) } catch { throw Failure.listenerFailed("\(error)") }
            self.listener = listener
            network.start(listener, state: { [weak self] state in self?.listenerChanged(state) },
                          connection: { [weak self] connection in self?.accept(connection) })
        }
        return try await withCheckedThrowingContinuation { ready.append($0) }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let value = listener?.port?.rawValue else { return }
            port = value
            let waiting = ready
            ready = []
            waiting.forEach { $0.resume(returning: value) }
        case .failed(let error):
            let waiting = ready
            ready = []
            listener?.cancel()
            listener = nil
            port = nil
            waiting.forEach { $0.resume(throwing: Failure.listenerFailed("\(error)")) }
        default:
            break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        let started = network.start(connection) { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.forget(id)
            default: break
            }
        }
        receive(started, head: Data())
    }

    private func forget(_ id: ObjectIdentifier) {
        connections[id] = nil
        for token in shares.keys { shares[token]?.streams[id] = nil }
    }

    private func receive(_ started: MainQueueConnection, head: Data) {
        network.receive(started, maximumLength: Self.headLimit) { [weak self] data, complete, error in
            guard let self else { return }
            var head = head
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: head[..<end.lowerBound], on: started.connection)
            } else if error != nil || complete || head.count > Self.headLimit {
                started.connection.cancel()
            } else {
                self.receive(started, head: head)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard request.count == 3, request[0] == "GET", Self.isLoopbackHost(host, port: port),
              let route = MarkdownLiveShareRoute(path: String(request[1])) else {
            return send(Self.response(404, type: "text/plain; charset=utf-8", body: Data("Not found\n".utf8)), on: connection, close: true)
        }
        switch route {
        case .page(let token):
            guard let share = shares[token] else { break }
            let events = "/md/\(token)/\(share.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token)/events"
            Task { [weak self, file = share.file, name = share.name] in // one off-main read per page request
                let text = await Task.detached { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }.value
                guard let page = self?.renderer.document(text, title: name, eventsPath: events) else { return connection.cancel() }
                self?.send(Self.response(200, type: "text/html; charset=utf-8", body: Data(page.utf8)), on: connection, close: true)
            }
            return
        case .events(let token):
            guard shares[token] != nil else { break }
            shares[token]?.streams[ObjectIdentifier(connection)] = connection
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n: connected\n\n"
            return send(Data(headers.utf8), on: connection, close: false)
        }
        send(Self.response(404, type: "text/plain; charset=utf-8", body: Data("Not found\n".utf8)), on: connection, close: true)
    }

    private func send(_ data: Data, on connection: NWConnection, close: Bool) {
        connection.send(content: data, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    // MARK: Changes

    private func watch(_ file: URL, token: String) -> FileChangeWatch {
        let watch = FileChangeWatch(url: file, inWorkspace: { true }, clock: clock) { [weak self] _ in
            self?.changed(token)
        }
        watch.start()
        return watch
    }

    private func changed(_ token: String) {
        guard let streams = shares[token]?.streams else { return }
        for connection in streams.values {
            connection.send(content: Data("data: reload\n\n".utf8), completion: .contentProcessed { _ in })
        }
    }

    // MARK: Helpers

    /// A DNS-rebound page names its own host; only the loopback names of this port are served.
    static func isLoopbackHost(_ host: String?, port: UInt16?) -> Bool {
        guard let host, let port else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    static func response(_ status: Int, type: String, body: Data) -> Data {
        let reason = status == 200 ? "OK" : "Not Found"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// 128 random bits, base64url without padding.
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The main-queue proof of ``MarkdownLiveShareServer``'s Network callbacks: it starts the listener and
/// every connection on the main queue itself, so each handler it installs runs on the main actor.
// Follow-up (debt, not a fix): move this adapter and MainQueueConnection to a lower package (CmuxNextWakeups or a
// Network seam package, with an internal init that keeps the proof local) when Package.swift is free of collisions;
// until then they keep about 34 lines in the App, which should be the composition root only.
// app-type-allow: this server's private main-queue seam; MainQueueConnection's fileprivate init keeps the proof in this file
private struct MainQueueNetworkEvents {
    /// Installs the listener's state and new-connection handlers, then starts it on the main queue.
    func start(_ listener: NWListener, state: @escaping @MainActor (NWListener.State) -> Void, connection: @escaping @MainActor (NWConnection) -> Void) {
        // main-proof: the listener starts on the main queue below.
        listener.stateUpdateHandler = { value in MainActor.assumeIsolated { state(value) } }
        // main-proof: the listener starts on the main queue below.
        listener.newConnectionHandler = { new in MainActor.assumeIsolated { connection(new) } }
        listener.start(queue: .main)
    }

    /// Installs the connection's state handler, then starts it on the main queue.
    ///
    /// - Returns: The proof that `connection` runs on the main queue, the only value ``receive(_:maximumLength:_:)`` takes.
    func start(_ connection: NWConnection, state: @escaping @MainActor (NWConnection.State) -> Void) -> MainQueueConnection {
        // main-proof: the connection starts on the main queue below.
        connection.stateUpdateHandler = { value in MainActor.assumeIsolated { state(value) } }
        connection.start(queue: .main)
        return MainQueueConnection(connection)
    }

    /// Reads up to `maximumLength` bytes from a connection this adapter started; `handler` gets the
    /// bytes, whether the peer finished, and the error.
    func receive(_ started: MainQueueConnection, maximumLength: Int, _ handler: @escaping @MainActor (Data?, Bool, NWError?) -> Void) {
        started.connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, done, error in
            // Only start(_:state:) makes a MainQueueConnection, and it calls connection.start(queue: .main) first.
            // main-proof: so Network calls this handler on the main queue.
            MainActor.assumeIsolated { handler(data, done, error) }
        }
    }
}

/// A connection ``MainQueueNetworkEvents`` started on the main queue; only its `start(_:state:)` makes one.
private struct MainQueueConnection {
    let connection: NWConnection

    fileprivate init(_ connection: NWConnection) { self.connection = connection }
}
