import Foundation
import OwlMojoBindingsGenerated
import OwlMojoSystem

public final class OwlFreshClientDirectMojoReceiver {
    private let reader: MojoMessagePeeking
    private let closer: MojoMessagePipeCreating
    private let receiverHandle: MojoHandle
    private let sink: OwlFreshClientMojoSink
    private var ownsReceiverHandle = true

    public init(
        reader: MojoMessagePeeking,
        closer: MojoMessagePipeCreating,
        receiverHandle: UInt64,
        sink: OwlFreshClientMojoSink
    ) {
        self.reader = reader
        self.closer = closer
        self.receiverHandle = MojoHandle(rawValue: UInt(receiverHandle))
        self.sink = sink
    }

    deinit {
        if ownsReceiverHandle {
            try? closer.close(receiverHandle)
        }
    }

    @discardableResult
    public func drainAvailableMessages(limit: Int = 256) throws -> Int {
        var count = 0
        while count < limit, let message = try reader.readMessageIfAvailable(pipe: receiverHandle) {
            try OwlFreshClientWireMessage.dispatch(message, to: sink)
            count += 1
        }
        return count
    }
}

public enum OwlFreshClientWireMessage {
    public enum Method: UInt32 {
        case onReady = 0
        case onCompositorChanged = 1
        case onSurfaceTreeChanged = 2
        case onNavigationChanged = 3
        case onHostLog = 4
        case onCursorChanged = 5
    }

    private static let isResponseFlag: UInt32 = 1 << 1
    private static let payloadPointerOffset = 32

    public static func dispatch(_ data: Data, to sink: OwlFreshClientMojoSink) throws {
        guard let method = Method(rawValue: try data.mojoUInt32(at: 12)) else {
            throw MojoWireDataError.invalidResponse("unknown OwlFreshClient method \(try data.mojoUInt32(at: 12))")
        }
        let flags = try data.mojoUInt32(at: 16)
        guard flags & isResponseFlag == 0 else {
            throw MojoWireDataError.invalidResponse("OwlFreshClient method \(method.rawValue) was marked as a response")
        }
        let payloadOffset = try data.mojoRelativeOffset(pointerOffset: payloadPointerOffset)
        switch method {
        case .onReady:
            sink.onReady(try readReady(data, payloadOffset: payloadOffset))
        case .onCompositorChanged:
            sink.onCompositorChanged(try readCompositor(data, pointerOffset: payloadOffset + 8))
        case .onSurfaceTreeChanged:
            let treeOffset = try data.mojoRelativeOffset(pointerOffset: payloadOffset + 8)
            sink.onSurfaceTreeChanged(try OwlFreshSurfaceTreeWireCodec.readSurfaceTree(data, at: treeOffset))
        case .onNavigationChanged:
            sink.onNavigationChanged(try readNavigation(data, payloadOffset: payloadOffset))
        case .onHostLog:
            sink.onHostLog(try data.mojoString(pointerOffset: payloadOffset + 8))
        case .onCursorChanged:
            sink.onCursorChanged(try readCursor(data, pointerOffset: payloadOffset + 8))
        }
    }

    public static func onReadyMessage(hostPID: Int32, compositor: OwlFreshCompositorInfo) -> Data {
        var payload = Data(count: 24)
        payload.writeUInt32(24, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.writeInt32(hostPID, at: 8)
        payload.appendMojoPointer(child: compositorData(compositor), pointerOffset: 16)
        return MojoWireMessage.message(method: Method.onReady.rawValue, payload: payload)
    }

    public static func onCompositorChangedMessage(_ compositor: OwlFreshCompositorInfo) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.appendMojoPointer(child: compositorData(compositor), pointerOffset: 8)
        return MojoWireMessage.message(method: Method.onCompositorChanged.rawValue, payload: payload)
    }

    public static func onSurfaceTreeChangedMessage(_ surfaceTree: OwlFreshSurfaceTree) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.appendMojoPointer(child: OwlFreshSurfaceTreeWireCodec.surfaceTreeData(surfaceTree), pointerOffset: 8)
        return MojoWireMessage.message(method: Method.onSurfaceTreeChanged.rawValue, payload: payload)
    }

    public static func onNavigationChangedMessage(
        url: String,
        title: String,
        loading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) -> Data {
        let urlData = MojoWireMessage.utf8String(url)
        let titleData = MojoWireMessage.utf8String(title)
        var payload = Data(count: 32)
        payload.writeUInt32(32, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.appendMojoPointer(child: urlData, pointerOffset: 8)
        payload.appendMojoPointer(child: titleData, pointerOffset: 16)
        payload[24] =
            (loading ? 1 : 0) |
            (canGoBack ? 1 << 1 : 0) |
            (canGoForward ? 1 << 2 : 0)
        return MojoWireMessage.message(method: Method.onNavigationChanged.rawValue, payload: payload)
    }

    public static func onHostLogMessage(_ message: String) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.appendMojoPointer(child: MojoWireMessage.utf8String(message), pointerOffset: 8)
        return MojoWireMessage.message(method: Method.onHostLog.rawValue, payload: payload)
    }

    public static func onCursorChangedMessage(_ cursor: OwlFreshCursorInfo) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.appendMojoPointer(child: cursorData(cursor), pointerOffset: 8)
        return MojoWireMessage.message(method: Method.onCursorChanged.rawValue, payload: payload)
    }

    private static func readReady(_ data: Data, payloadOffset: Int) throws -> OwlFreshClientOnReadyRequest {
        OwlFreshClientOnReadyRequest(
            hostPid: try data.mojoInt32(at: payloadOffset + 8),
            compositor: try readCompositor(data, pointerOffset: payloadOffset + 16)
        )
    }

    private static func readNavigation(_ data: Data, payloadOffset: Int) throws -> OwlFreshClientOnNavigationChangedRequest {
        let flags = try data.mojoUInt8(at: payloadOffset + 24)
        return OwlFreshClientOnNavigationChangedRequest(
            url: try data.mojoString(pointerOffset: payloadOffset + 8),
            title: try data.mojoString(pointerOffset: payloadOffset + 16),
            loading: flags & 1 != 0,
            canGoBack: flags & (1 << 1) != 0,
            canGoForward: flags & (1 << 2) != 0
        )
    }

    private static func readCompositor(_ data: Data, pointerOffset: Int) throws -> OwlFreshCompositorInfo {
        let compositorOffset = try data.mojoRelativeOffset(pointerOffset: pointerOffset)
        return OwlFreshCompositorInfo(contextId: try data.mojoUInt32(at: compositorOffset + 8))
    }

    private static func readCursor(_ data: Data, pointerOffset: Int) throws -> OwlFreshCursorInfo {
        let cursorOffset = try data.mojoRelativeOffset(pointerOffset: pointerOffset)
        return OwlFreshCursorInfo(type: try data.mojoInt32(at: cursorOffset + 8))
    }

    private static func compositorData(_ compositor: OwlFreshCompositorInfo) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(compositor.contextId, at: 8)
        return data
    }

    private static func cursorData(_ cursor: OwlFreshCursorInfo) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeInt32(cursor.type, at: 8)
        return data
    }
}
