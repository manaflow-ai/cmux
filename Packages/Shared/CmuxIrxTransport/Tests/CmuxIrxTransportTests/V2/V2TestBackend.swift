import Foundation
@testable import CmuxIrxTransport

actor V2TestBackend {
    var handshakes: [V2SocketSetup] = []
    var authorizations: [String] = []
    var sockets: [V2TestSocket] = []
    var failSockets = false
    var httpRequests: [URLRequest] = []
    var enrolled: Bool
    let now: Int
    let holdRegistration: Bool
    var socketObserved: CheckedContinuation<V2TestSocket, Never>?
    let directoryRules: [String]?
    let directoryPageRules: [[String]?]?

    init(now: Int, enrolled: Bool = false, holdRegistration: Bool = false, directoryRules: [String]? = nil, directoryPageRules: [[String]?]? = nil) {
        self.now = now
        self.enrolled = enrolled
        self.holdRegistration = holdRegistration
        self.directoryRules = directoryRules
        self.directoryPageRules = directoryPageRules
    }

    func connect(_ request: URLRequest) async throws -> any V2ControlSocket {
        if failSockets { throw URLError(.cannotConnectToHost) }
        let header = request.value(forHTTPHeaderField: "x-cmux-v2-setup")!
        let base64 = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))!
        let setup = try JSONDecoder().decode(V2SocketSetup.self, from: data)
        handshakes.append(setup)
        authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let socket = V2TestSocket(device: setup.device, now: now, directoryRules: directoryRules, directoryPageRules: directoryPageRules)
        if holdRegistration { await socket.holdRegistration() }
        sockets.append(socket)
        socketObserved?.resume(returning: socket)
        socketObserved = nil
        try await socket.prepare(setup, enrolled: enrolled)
        return socket
    }

    func markEnrolled() { enrolled = true }
    func disableSockets() { failSockets = true }
    func currentSocket() -> V2TestSocket { sockets.last! }
    func waitForSocket() async -> V2TestSocket {
        if let socket = sockets.last { return socket }
        return await withCheckedContinuation { socketObserved = $0 }
    }

    func http(_ request: URLRequest) async throws -> V2HTTPResponse {
        httpRequests.append(request)
        if request.url?.path == "/v2/control/session" {
            let setup = try JSONDecoder().decode(V2SocketSetup.self, from: request.httpBody!)
            let temporary = V2TestSocket(device: setup.device, now: now, directoryRules: directoryRules, directoryPageRules: directoryPageRules)
            try await temporary.prepare(setup, enrolled: enrolled)
            return V2HTTPResponse(status: 200, body: try await temporary.receive(), retryAfter: nil)
        }
        let header = request.value(forHTTPHeaderField: "x-cmux-v2-setup")!
        let base64 = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))!
        let setup = try JSONDecoder().decode(V2SocketSetup.self, from: data)
        let temporary = V2TestSocket(device: setup.device, now: now, directoryRules: directoryRules, directoryPageRules: directoryPageRules)
        try await temporary.send(request.httpBody!)
        if let registration = try? JSONDecoder().decode(V2RegisterRequest.self, from: request.httpBody!), registration.schemaID == .deviceRegisterV1 { enrolled = true }
        return V2HTTPResponse(status: 200, body: try await temporary.receive(), retryAfter: nil)
    }
}
