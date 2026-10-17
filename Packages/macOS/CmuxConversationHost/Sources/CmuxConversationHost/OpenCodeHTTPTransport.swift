public import Foundation
public import CmuxConversation
import Darwin

/// Starts a private, authenticated OpenCode server in the selected workspace.
public struct OpenCodeHTTPTransportFactory: ConversationNativeTransportFactory {
    private let executableOverride: String?
    public init(executableOverride: String? = nil) { self.executableOverride = executableOverride }
    public func make(provider: ConversationProvider, session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationNativeTransport {
        guard provider == .openCode else { throw ConversationProviderError.unsupported("This transport serves OpenCode only") }
        let server = try await OpenCodeServerProcess.open(target: target, executableOverride: executableOverride)
        do { return try await OpenCodeHTTPTransport.open(server: server, directory: session.directory) }
        catch { await server.close(); throw error }
    }
}

/// Credentials stay in memory, and SSH passes its disposable password on stdin.
fileprivate actor OpenCodeServerProcess {
    let endpoint: URL
    let password: String
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let chunks: AsyncThrowingStream<Data, any Error>
    private let finishChunks: AsyncThrowingStream<Data, any Error>.Continuation
    private var closed = false
    private var reapTask: Task<Void, Never>?
    private let expectedRemotePort: Int?

    static func open(target: ConversationLaunchTarget, executableOverride: String?) async throws -> OpenCodeServerProcess {
        let server = try OpenCodeServerProcess(target: target, executableOverride: executableOverride)
        do { try await server.ready(); return server } catch { await server.close(); throw error }
    }

    private init(target: ConversationLaunchTarget, executableOverride: String?) throws {
        let port = try Self.availablePort()
        endpoint = URL(string: "http://127.0.0.1:\(port)")!
        password = UUID().uuidString + UUID().uuidString
        let process = Process(); let stdin = Pipe(); let stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let args = ["serve", "--hostname", "127.0.0.1", "--port", String(port)]
        switch target {
        case .local(let directory):
            let candidates = [executableOverride].compactMap { $0 } + ["\(NSHomeDirectory())/.opencode/bin/opencode", "\(NSHomeDirectory())/.local/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/opencode" }
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ConversationProviderError.unavailable("Install OpenCode on the selected Mac") }
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            process.environment = ProcessInfo.processInfo.environment.merging(["OPENCODE_SERVER_PASSWORD": password, "OPENCODE_DISABLE_AUTOUPDATE": "true"]) { _, new in new }
            expectedRemotePort = nil
        case .ssh(let host, let directory, let arguments):
            // The remote server stays on its loopback. SSH owns the only tunnel.
            let remotePort = Int.random(in: 32_768...60_999)
            let command = "IFS= read -r OPENCODE_SERVER_PASSWORD && export OPENCODE_SERVER_PASSWORD && cd -- \(ProcessConversationTransportFactory.shellQuote(directory)) && exec opencode serve --hostname 127.0.0.1 --port \(remotePort)"
            let remote = "exec \"${SHELL:-/bin/sh}\" -lc \(ProcessConversationTransportFactory.shellQuote(command))"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments + ["-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:\(port):127.0.0.1:\(remotePort)", "--", host, remote]
            expectedRemotePort = remotePort
        case .cloud: throw ConversationProviderError.unsupported("This workspace does not expose a native OpenCode connection")
        }
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        chunks = pair.stream; finishChunks = pair.continuation
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { pair.continuation.finish(); return }
            if case .dropped = pair.continuation.yield(data) { pair.continuation.finish(throwing: ConversationProviderError.unavailable("OpenCode startup output overflow")) }
        }
        do {
            try process.run()
            if expectedRemotePort != nil { try input.write(contentsOf: Data((password + "\n").utf8)) }
        } catch {
            output.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            throw ConversationProviderError.unavailable("OpenCode server could not start")
        }
    }

    private func ready() async throws {
        let stream = chunks
        let expected = expectedRemotePort ?? endpoint.port!
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var bytes = Data()
                for try await chunk in stream {
                    bytes.append(chunk)
                    guard bytes.count <= 65_536 else { throw ConversationProviderError.malformed("OpenCode startup output exceeded the limit") }
                    let text = String(decoding: bytes, as: UTF8.self)
                    if text.contains("http://127.0.0.1:\(expected)") { return }
                }
                throw ConversationProviderError.unavailable("OpenCode server ended before becoming ready")
            }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw ConversationProviderError.unavailable("OpenCode server startup timed out") }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        // No log content is retained or sent to the phone after the readiness signal.
        output.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
        finishChunks.finish()
    }

    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ConversationProviderError.unavailable("Could not reserve a local server address") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw ConversationProviderError.unavailable("Could not reserve a local server address") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard read == 0 else { throw ConversationProviderError.unavailable("Could not resolve a local server address") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    func close() async {
        guard !closed else { return }; closed = true
        output.readabilityHandler = nil; finishChunks.finish()
        try? input.close(); try? output.close()
        if process.isRunning {
            process.terminate()
            reapTask = Task { [self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                reapTask = nil
            }
        }
    }
}

/// A bounded HTTP/SSE transport with no automatic request retries.
actor OpenCodeHTTPTransport: ConversationNativeTransport {
    nonisolated let messages: AsyncThrowingStream<ConversationJSONValue, any Error>
    private let continuation: AsyncThrowingStream<ConversationJSONValue, any Error>.Continuation
    private let server: OpenCodeServerProcess
    private let session: URLSession
    private let endpoint: URL
    private let authorization: String
    private let directory: String
    private var reader: Task<Void, Never>?
    private var closed = false

    private init(server: OpenCodeServerProcess, endpoint: URL, password: String, directory: String) {
        self.server = server; self.endpoint = endpoint; self.directory = directory
        authorization = "Basic " + Data(("opencode:" + password).utf8).base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 86_400
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: OpenCodeRedirectPolicy(), delegateQueue: nil)
        let pair = AsyncThrowingStream<ConversationJSONValue, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        messages = pair.stream; continuation = pair.continuation
    }

    fileprivate static func open(server: OpenCodeServerProcess, directory: String) async throws -> OpenCodeHTTPTransport {
        let transport = OpenCodeHTTPTransport(server: server, endpoint: await server.endpoint, password: await server.password, directory: directory)
        do { try await transport.startEvents(); return transport } catch { await transport.close(); throw error }
    }

    private func request(path: String, method: String, body: ConversationJSONValue? = nil) throws -> URLRequest {
        guard !closed else { throw ConversationProviderError.unavailable("OpenCode connection is closed") }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = path; components.queryItems = [URLQueryItem(name: "directory", value: directory)]
        guard let url = components.url else { throw ConversationProviderError.malformed("Invalid OpenCode endpoint") }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        return request
    }

    private func startEvents() async throws {
        let (bytes, response) = try await session.bytes(for: request(path: "/event", method: "GET"))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw ConversationProviderError.unavailable("OpenCode event subscription failed") }
        reader = Task { [weak self] in
            var decoder = OpenCodeSSEDecoder()
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if let value = try decoder.append(byte) { try await self?.emit(value) }
                }
                await self?.ended(ConversationProviderError.unavailable("OpenCode event stream ended"))
            } catch { await self?.ended(error) }
        }
    }

    func send(_ payload: ConversationJSONValue) async throws -> ConversationJSONValue? {
        guard let object = payload.objectValue, let method = object["method"]?.stringValue else { throw ConversationProviderError.rejected("Invalid OpenCode request") }
        let params = object["params"]?.objectValue ?? [:]
        let path: String; let verb: String; let body: ConversationJSONValue?
        switch method {
        case "session.create": path = "/session"; verb = "POST"; body = .object(params)
        case "provider.list": path = "/provider"; verb = "GET"; body = nil
        case "session.get": path = "/session/\(try identifier(params["sessionID"]))"; verb = "GET"; body = nil
        case "session.prompt": path = "/session/\(try identifier(params["sessionID"]))/prompt_async"; verb = "POST"; body = params["body"]
        case "session.abort": path = "/session/\(try identifier(params["sessionID"]))/abort"; verb = "POST"; body = .object([:])
        case "permission.reply": path = "/permission/\(try identifier(params["requestID"]))/reply"; verb = "POST"; body = params["body"]
        case "question.reply": path = "/question/\(try identifier(params["requestID"]))/reply"; verb = "POST"; body = params["body"]
        default: throw ConversationProviderError.unsupported("OpenCode does not expose this operation")
        }
        let (bytes, response) = try await session.bytes(for: request(path: path, method: verb, body: body))
        guard let response = response as? HTTPURLResponse else { throw ConversationProviderError.unavailable("OpenCode returned no HTTP response") }
        guard (200..<300).contains(response.statusCode) else {
            if (400..<500).contains(response.statusCode) { throw ConversationProviderError.rejected("OpenCode rejected the request (\(response.statusCode))") }
            throw ConversationProviderError.unavailable("OpenCode response failed; delivery is uncertain")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 8_388_608 else { throw ConversationProviderError.malformed("OpenCode response exceeds the limit") }
        }
        if data.isEmpty { return .null }
        return try JSONDecoder().decode(ConversationJSONValue.self, from: data)
    }

    private func identifier(_ value: ConversationJSONValue?) throws -> String {
        guard let value = value?.stringValue, !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw ConversationProviderError.rejected("Invalid native identifier") }
        return value
    }
    private func emit(_ value: ConversationJSONValue) throws {
        if case .dropped = continuation.yield(value) { throw ConversationProviderError.unavailable("OpenCode event buffer overflow") }
    }
    private func ended(_ error: any Error) async {
        guard !closed else { return }
        continuation.finish(throwing: error)
        await close()
    }
    func close() async {
        guard !closed else { return }; closed = true
        reader?.cancel(); reader = nil; continuation.finish()
        session.invalidateAndCancel(); await server.close()
    }
}

/// Refuse redirects so the disposable credential never follows a new origin.
private final class OpenCodeRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct OpenCodeSSEDecoder {
    private var line = Data()
    private var event = Data()
    private let maximumBytes: Int
    init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }
    mutating func append(_ byte: UInt8) throws -> ConversationJSONValue? {
        if byte != 10 {
            line.append(byte)
            guard line.count <= maximumBytes else { throw ConversationProviderError.malformed("OpenCode event line exceeds the limit") }
            return nil
        }
        defer { line.removeAll(keepingCapacity: true) }
        if line.last == 13 { line.removeLast() }
        if line.isEmpty {
            guard !event.isEmpty else { return nil }
            defer { event.removeAll(keepingCapacity: true) }
            return try JSONDecoder().decode(ConversationJSONValue.self, from: event)
        }
        if line.starts(with: Data("data:".utf8)) {
            var data = line.dropFirst(5)
            if data.first == 32 { data = data.dropFirst() }
            if !event.isEmpty { event.append(10) }; event.append(contentsOf: data)
            guard event.count <= maximumBytes else { throw ConversationProviderError.malformed("OpenCode event exceeds the limit") }
        }
        return nil
    }
}
