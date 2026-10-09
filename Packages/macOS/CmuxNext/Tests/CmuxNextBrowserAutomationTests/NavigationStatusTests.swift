import CmuxNextBrowser
import Foundation
import Network
import Synchronization
import Testing
import WebKit
@testable import CmuxNextBrowserAutomation

/// `tab.navigate`, `tab.reload` and `tab.history` report the main frame's
/// HTTP status, as `page.goto()` and `page.reload()` return it (`Response
/// .status()`, `ok()`); a page without an HTTP response (a data URL) has
/// none.
@MainActor
@Suite(.serialized) struct NavigationStatusTests {
    @Test func navigationsReportTheMainFrameStatus() async throws {
        let server = try await StatusServer.start()
        defer { server.stop() }
        let provider = DriverCallTests.FakeProvider()
        let driver = WebKitDriver(provider: provider)
        let opened = try await driver.call(method: "tabs.open", params: .object([:]))
        guard case .object(let fields) = opened, case .string(let id)? = fields["targetId"] else {
            Issue.record("tabs.open returned \(opened)")
            return
        }
        func navigate(_ url: String) async throws -> DriverJSON? {
            let reply = try await driver.call(method: "tab.navigate", params: .object([
                "targetId": .string(id), "url": .string(url), "waitUntil": .string("load"), "timeoutMs": .number(15000),
            ]))
            guard case .object(let fields) = reply else { return nil }
            return fields["status"]
        }
        let base = "http://127.0.0.1:\(server.port)"
        #expect(try await navigate("\(base)/ok") == .number(200))
        #expect(try await navigate("\(base)/missing") == .number(404))
        let reload = try await driver.call(method: "tab.reload", params: .object([
            "targetId": .string(id), "waitUntil": .string("load"), "timeoutMs": .number(15000),
        ]))
        guard case .object(let reloaded) = reload else { Issue.record("tab.reload returned \(reload)"); return }
        #expect(reloaded["status"] == .number(404))
        let back = try await driver.call(method: "tab.history", params: .object([
            "targetId": .string(id), "delta": .number(-1), "waitUntil": .string("load"), "timeoutMs": .number(15000),
        ]))
        guard case .object(let wentBack) = back else { Issue.record("tab.history returned \(back)"); return }
        #expect(wentBack["status"] == .number(200))
        #expect(try await navigate("data:text/html,<p>no%20http</p>") == nil)
        _ = try await driver.call(method: "tabs.close", params: .object(["targetId": .string(id)]))
    }
}

/// An HTTP server on 127.0.0.1: `/missing` answers 404, any other path 200.
nonisolated final class StatusServer {
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> StatusServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "status.server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.serve(connection, buffer: Data())
        }
        let port: UInt16 = await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                guard case .ready = state, let port = listener.port?.rawValue,
                      resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: port)
            }
            listener.start(queue: queue)
        }
        return StatusServer(listener: listener, port: port)
    }

    private static func serve(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, complete, error in
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            guard buffer.contains(Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { serve(connection, buffer: buffer) }
                return
            }
            let line = String(decoding: buffer, as: UTF8.self).split(separator: "\r\n").first ?? ""
            let missing = line.contains(" /missing ")
            let body = missing ? "<title>Missing</title>missing" : "<title>OK</title>ok"
            let status = missing ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func stop() { listener.cancel() }
}
