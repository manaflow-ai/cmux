public import Foundation

final class CmuxTUIUpdateSink: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

let cmuxTUIUpdateCallback: CmuxTUIUpdateCallback = { context in
    guard let context else { return }
    Unmanaged<CmuxTUIUpdateSink>
        .fromOpaque(context)
        .takeUnretainedValue()
        .continuation
        .yield()
}

private struct CmuxTUIConnectedHandle: Sendable {
    let rawAddress: UInt?
    let error: String
}

private struct CmuxTUIAttachedHandle: Sendable {
    let rawAddress: UInt?
    let error: String
}

private func cmuxTUITimeoutMilliseconds(_ timeout: Duration) -> UInt64 {
    let components = timeout.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return 1 }
    let seconds = UInt64(components.seconds)
    guard seconds <= UInt64.max / 1_000 else { return UInt64.max }
    let wholeMilliseconds = seconds * 1_000
    let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
    let fractionalMilliseconds = UInt64(
        components.attoseconds / attosecondsPerMillisecond
            + (components.attoseconds % attosecondsPerMillisecond == 0 ? 0 : 1)
    )
    let (milliseconds, overflow) = wholeMilliseconds.addingReportingOverflow(
        fractionalMilliseconds
    )
    return overflow ? UInt64.max : max(1, milliseconds)
}

public actor CmuxTUIFrontendClient {
    private let library: CmuxTUIClientLibrary
    private var raw: OpaquePointer?
    private var updateSink: CmuxTUIUpdateSink?
    private var updateGeneration: UInt64 = 0
    private var inFlightBlockingOperations = 0
    private var shutdownRequested = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    private init(library: CmuxTUIClientLibrary, rawAddress: UInt) {
        self.library = library
        raw = OpaquePointer(bitPattern: rawAddress)
    }

    public static func connect(
        invitation: String,
        timeout: Duration = .seconds(20)
    ) async throws -> CmuxTUIFrontendClient {
        guard let library = CmuxTUIClientLibrary.shared else {
            throw CmuxTUIClientError.libraryUnavailable(
                searchedPaths: CmuxTUIClientLibrary.defaultLibraryPaths
            )
        }
        let timeoutMilliseconds = cmuxTUITimeoutMilliseconds(timeout)
        let result = await Task.detached(priority: .userInitiated) {
            var error = [CChar](repeating: 0, count: 4_096)
            let handle = library.connect(
                invitation: invitation,
                errorBuffer: &error,
                timeoutMilliseconds: timeoutMilliseconds
            )
            return CmuxTUIConnectedHandle(
                rawAddress: handle.map { UInt(bitPattern: $0) },
                error: Self.decodeError(error)
            )
        }.value
        guard let rawAddress = result.rawAddress else {
            throw CmuxTUIClientError.message(result.error)
        }
        return CmuxTUIFrontendClient(library: library, rawAddress: rawAddress)
    }

    public func request(
        operation: String,
        paramsJSON: Data = Data("{}".utf8),
        mutation: Bool = false
    ) async throws -> Data {
        let (library, rawAddress) = try beginBlockingOperation()
        defer { finishBlockingOperation() }
        guard let params = String(data: paramsJSON, encoding: .utf8) else {
            throw CmuxTUIClientError.message("request params are not UTF-8")
        }
        let result = await Task.detached(priority: .userInitiated) {
            var error = [CChar](repeating: 0, count: 4_096)
            guard let value = library.request(
                client: OpaquePointer(bitPattern: rawAddress),
                operation: operation,
                paramsJSON: params,
                mutation: mutation,
                errorBuffer: &error
            ) else {
                return Result<Data, CmuxTUIClientError>.failure(
                    .message(Self.decodeError(error))
                )
            }
            defer { library.free(string: value) }
            return .success(Data(String(cString: value).utf8))
        }.value
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    public func request<Response: Decodable & Sendable>(
        operation: String,
        paramsJSON: Data = Data("{}".utf8),
        mutation: Bool = false,
        as _: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await request(
            operation: operation,
            paramsJSON: paramsJSON,
            mutation: mutation
        )
        return try JSONDecoder().decode(Response.self, from: data)
    }

    public func attachTerminal(
        publicID: String,
        timeout: Duration = .seconds(15)
    ) async throws -> CmuxTUITerminal {
        let (library, rawAddress) = try beginBlockingOperation()
        defer { finishBlockingOperation() }
        let timeoutMilliseconds = cmuxTUITimeoutMilliseconds(timeout)
        let result = await Task.detached(priority: .userInitiated) {
            var error = [CChar](repeating: 0, count: 4_096)
            let terminal = library.attachTerminal(
                client: OpaquePointer(bitPattern: rawAddress),
                publicID: publicID,
                errorBuffer: &error,
                timeoutMilliseconds: timeoutMilliseconds
            )
            return CmuxTUIAttachedHandle(
                rawAddress: terminal.map { UInt(bitPattern: $0) },
                error: Self.decodeError(error)
            )
        }.value
        guard let terminalAddress = result.rawAddress else {
            throw CmuxTUIClientError.message(result.error)
        }
        guard !shutdownRequested else {
            library.disconnectTerminal(OpaquePointer(bitPattern: terminalAddress))
            throw CmuxTUIClientError.message("frontend connection closed")
        }
        return CmuxTUITerminal(
            library: library,
            rawAddress: terminalAddress
        )
    }

    public func updates() -> CmuxTUIUpdateSubscription {
        stopUpdates()
        updateGeneration &+= 1
        let generation = updateGeneration
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard let raw else {
            pair.continuation.finish()
            return CmuxTUIUpdateSubscription(generation: generation, stream: pair.stream)
        }
        let sink = CmuxTUIUpdateSink(pair.continuation)
        updateSink = sink
        library.setClientUpdateCallback(
            raw,
            callback: cmuxTUIUpdateCallback,
            context: Unmanaged.passUnretained(sink).toOpaque()
        )
        return CmuxTUIUpdateSubscription(generation: generation, stream: pair.stream)
    }

    public func stopUpdates(generation: UInt64? = nil) {
        if let generation, generation != updateGeneration { return }
        guard let sink = updateSink else { return }
        if let raw {
            library.setClientUpdateCallback(raw, callback: nil, context: nil)
        }
        sink.continuation.finish()
        updateSink = nil
        updateGeneration &+= 1
    }

    public func diagnostics() -> String {
        library.clientDiagnostics(raw)
    }

    public func shutdown() async {
        guard !shutdownRequested else { return }
        shutdownRequested = true
        if inFlightBlockingOperations > 0 {
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        }
        stopUpdates()
        guard let raw else { return }
        self.raw = nil
        library.disconnectClient(raw)
    }

    private func beginBlockingOperation() throws -> (CmuxTUIClientLibrary, UInt) {
        guard !shutdownRequested, let raw else {
            throw CmuxTUIClientError.message("frontend connection closed")
        }
        inFlightBlockingOperations += 1
        return (library, UInt(bitPattern: raw))
    }

    private func finishBlockingOperation() {
        precondition(inFlightBlockingOperations > 0)
        inFlightBlockingOperations -= 1
        guard inFlightBlockingOperations == 0 else { return }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private static func decodeError(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
