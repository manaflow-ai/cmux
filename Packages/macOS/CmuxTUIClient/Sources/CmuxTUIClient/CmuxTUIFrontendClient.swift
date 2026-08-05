public import Foundation

final class CmuxTUIUpdateSink: @unchecked Sendable {
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
    ) throws -> Data {
        guard let raw else { throw CmuxTUIClientError.message("frontend connection closed") }
        guard let params = String(data: paramsJSON, encoding: .utf8) else {
            throw CmuxTUIClientError.message("request params are not UTF-8")
        }
        var error = [CChar](repeating: 0, count: 4_096)
        guard let result = library.request(
            client: raw,
            operation: operation,
            paramsJSON: params,
            mutation: mutation,
            errorBuffer: &error
        ) else {
            throw CmuxTUIClientError.message(Self.decodeError(error))
        }
        defer { library.free(string: result) }
        return Data(String(cString: result).utf8)
    }

    public func request<Response: Decodable & Sendable>(
        operation: String,
        paramsJSON: Data = Data("{}".utf8),
        mutation: Bool = false,
        as _: Response.Type = Response.self
    ) throws -> Response {
        let data = try request(
            operation: operation,
            paramsJSON: paramsJSON,
            mutation: mutation
        )
        return try JSONDecoder().decode(Response.self, from: data)
    }

    public func attachTerminal(
        publicID: String,
        timeout: Duration = .seconds(15)
    ) throws -> CmuxTUITerminal {
        guard let raw else { throw CmuxTUIClientError.message("frontend connection closed") }
        let timeoutMilliseconds = cmuxTUITimeoutMilliseconds(timeout)
        var error = [CChar](repeating: 0, count: 4_096)
        guard let terminal = library.attachTerminal(
            client: raw,
            publicID: publicID,
            errorBuffer: &error,
            timeoutMilliseconds: timeoutMilliseconds
        ) else {
            throw CmuxTUIClientError.message(Self.decodeError(error))
        }
        return CmuxTUITerminal(
            library: library,
            rawAddress: UInt(bitPattern: terminal)
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

    public func shutdown() {
        stopUpdates()
        guard let raw else { return }
        self.raw = nil
        library.disconnectClient(raw)
    }

    private static func decodeError(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
