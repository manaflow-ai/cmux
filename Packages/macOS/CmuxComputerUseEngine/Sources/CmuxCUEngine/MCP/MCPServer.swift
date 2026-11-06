// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// MCP over newline-delimited JSON-RPC on any byte stream (stdio or one
/// accepted socket connection). Calls on one connection run in order; the
/// reply is written as soon as it is ready.
public final class MCPConnection: @unchecked Sendable {
    let engine: Engine
    let input: FileHandle
    let output: FileHandle
    private let writeLock = NSLock()
    /// Per-call timings go in `_meta` so a bench can split the work.
    public var reportTimings = true

    public init(engine: Engine, input: FileHandle, output: FileHandle) {
        self.engine = engine
        self.input = input
        self.output = output
    }

    /// Serves until the input closes. Lines are handled one at a time, in
    /// order. The blocking read runs on its own thread and hands complete
    /// lines over, so no Swift concurrency thread ever waits on the socket.
    public func serve() async {
        let (lines, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let input = self.input
        let reader = Thread {
            var buffer = Data()
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { continuation.yield(line) }
                }
            }
            continuation.finish()
        }
        reader.name = "cmux.cu.mcp-read"
        reader.qualityOfService = .userInitiated
        reader.start()
        for await line in lines {
            await handle(line)
        }
    }

    func handle(_ line: Data) async {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            return
        }
        let id = message["id"]
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return } // notifications need no answer
        switch method {
        case "initialize":
            let version = (params["protocolVersion"] as? String) ?? "2025-06-18"
            reply(id, ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]],
                       "serverInfo": ["name": "cmux-computer-use", "version": "0.1.0"]])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": ToolCatalog.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "tools/call needs a name"]])
                return
            }
            let clock = ContinuousClock()
            let start = clock.now
            let result = await engine.call(name, params["arguments"] as? [String: Any] ?? [:])
            var timings = result.timings
            timings["engine_ms"] = ms(clock.now - start)
            reply(id, Self.encode(result, timings: reportTimings ? timings : nil))
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]])
        }
    }

    static func encode(_ result: ToolResult, timings: [String: Double]?) -> [String: Any] {
        var content: [[String: Any]] = []
        for block in result.blocks {
            switch block {
            case .text(let text): content.append(["type": "text", "text": text])
            case .jpeg(let data): content.append(["type": "image", "mimeType": "image/jpeg", "data": data.base64EncodedString()])
            }
        }
        var out: [String: Any] = ["content": content, "isError": result.isError]
        if let timings { out["_meta"] = ["cmux/timings": timings] }
        return out
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        writeLock.withLock { output.write(data) }
    }
}
