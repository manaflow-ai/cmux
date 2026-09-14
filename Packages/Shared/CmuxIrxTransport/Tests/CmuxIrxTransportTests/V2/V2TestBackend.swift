import Foundation
@testable import CmuxIrxTransport

actor V2TestBackend {
    var handshakes: [V2SocketSetup] = []
    var authorizations: [String] = []
    var sockets: [V2TestSocket] = []
    var enrolled: Bool
    let now: Int

    init(now: Int, enrolled: Bool = false) { self.now = now; self.enrolled = enrolled }

    func connect(_ request: URLRequest) async throws -> any V2ControlSocket {
        let header = request.value(forHTTPHeaderField: "x-cmux-v2-setup")!
        let base64 = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))!
        let setup = try JSONDecoder().decode(V2SocketSetup.self, from: data)
        handshakes.append(setup)
        authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let socket = V2TestSocket(device: setup.device, now: now)
        sockets.append(socket)
        try await socket.prepare(setup, enrolled: enrolled)
        return socket
    }

    func markEnrolled() { enrolled = true }
    func currentSocket() -> V2TestSocket { sockets.last! }
}
