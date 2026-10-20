import CryptoKit
import Foundation
@preconcurrency import Network

/// Minimal RFC6455 peer for testing Foundation's real handshake and socket cancellation, not a production server.
actor CloudAuthorityLoopbackConnection {
    enum Failure: Error { case closed, invalidHTTP, invalidFrame, oversized }
    private let connection: NWConnection
    private var input = Data()
    private var closed = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        connection.start(queue: queue)
    }

    func request() async throws -> (target: String, headers: [String: String]) {
        let terminator = Data("\r\n\r\n".utf8)
        while input.range(of: terminator) == nil {
            guard input.count <= 65_536 else { throw Failure.invalidHTTP }
            input.append(try await chunk())
        }
        guard let end = input.range(of: terminator), end.upperBound <= 65_536,
              let head = String(data: input[..<end.lowerBound], encoding: .utf8) else { throw Failure.invalidHTTP }
        input.removeSubrange(..<end.upperBound)
        let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" else { throw Failure.invalidHTTP }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw Failure.invalidHTTP }
            let key = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces)
            headers[key] = headers[key].map { $0 + ", " + value } ?? value
        }
        return (String(first[1]), headers)
    }

    func upgrade(_ headers: [String: String]) async throws {
        guard let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16,
              headers["upgrade"]?.lowercased() == "websocket",
              headers["sec-websocket-protocol"]?.split(separator: ",").contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "cmux.wire.v1"
              }) == true else { throw Failure.invalidHTTP }
        // RFC6455 sections4.2.2 and5.2; SHA1 here is the mandatory handshake checksum, not authentication.
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        try await send(Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: cmux.wire.v1\r\n\r\n").utf8))
    }

    func respond(status: Int, headers: [String: String] = [:]) async throws {
        var text = "HTTP/1.1 \(status) Test\r\nContent-Length: 0\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        try await send(Data((text + "\r\n").utf8))
        close()
    }

    func frame(_ payload: Data, opcode: UInt8 = 2) async throws {
        guard payload.count <= (8 << 20) + 1 else { throw Failure.oversized }
        var bytes = Data([0x80 | opcode])
        if payload.count < 126 { bytes.append(UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            bytes.append(126); bytes.append(UInt8(payload.count >> 8)); bytes.append(UInt8(payload.count & 255))
        } else {
            bytes.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((length >> shift) & 255)) }
        }
        bytes.append(payload)
        try await send(bytes)
    }

    func nextFrame() async throws -> (opcode: UInt8, payload: Data) {
        let head = try await read(2), opcode = head[0] & 15
        guard head[0] & 0xF0 == 0x80, head[1] & 0x80 != 0 else { throw Failure.invalidFrame }
        var length = UInt64(head[1] & 127)
        if length == 126 {
            let extra = try await read(2); length = UInt64(extra[0]) << 8 | UInt64(extra[1])
        } else if length == 127 {
            let extra = try await read(8)
            length = extra.reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard length <= 8 << 20 else { throw Failure.oversized }
        let mask = try await read(4), body = try await read(Int(length))
        return (opcode, Data(body.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
    }

    func waitForClientClose() async throws {
        do {
            while true {
                let frame = try await nextFrame()
                if frame.opcode == 8 { return }
                if frame.opcode == 9 { try await self.frame(frame.payload, opcode: 10) }
            }
        } catch Failure.closed { return }
        catch is NWError { return }
    }

    func close() { closed = true; connection.cancel() }

    private func read(_ count: Int) async throws -> Data {
        while input.count < count { input.append(try await chunk()) }
        let bytes = Data(input.prefix(count))
        input.removeFirst(count)
        return bytes
    }

    private func chunk() async throws -> Data {
        guard !closed else { throw Failure.closed }
        let connection = connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if done { continuation.resume(throwing: Failure.closed) }
                    else { continuation.resume(throwing: Failure.invalidFrame) }
                }
            }
        } onCancel: { connection.cancel() }
    }

    private func send(_ bytes: Data) async throws {
        guard !closed else { throw Failure.closed }
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }
}
