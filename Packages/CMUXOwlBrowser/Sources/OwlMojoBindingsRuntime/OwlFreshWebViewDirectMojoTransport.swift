import Foundation
import OwlMojoBindingsGenerated
import OwlMojoSystem

public final class OwlFreshWebViewDirectMojoTransport {
    private let writer: MojoMessageWriting
    private let closer: MojoMessagePipeCreating
    private let remoteHandle: MojoHandle
    private var ownsRemoteHandle = true

    public init(writer: MojoMessageWriting, closer: MojoMessagePipeCreating, remoteHandle: UInt64) {
        self.writer = writer
        self.closer = closer
        self.remoteHandle = MojoHandle(rawValue: UInt(remoteHandle))
    }

    deinit {
        if ownsRemoteHandle {
            try? closer.close(remoteHandle)
        }
    }

    public func navigate(to url: String) throws {
        try write(method: .navigate, payload: OwlFreshWebViewWireMessage.navigatePayload(url: url))
    }

    public func resize(_ request: OwlFreshWebViewResizeRequest) throws {
        try write(method: .resize, payload: OwlFreshWebViewWireMessage.resizePayload(request))
    }

    public func setFocus(_ focused: Bool) throws {
        try write(method: .setFocus, payload: OwlFreshWebViewWireMessage.setFocusPayload(focused))
    }

    public func goBack() throws {
        try write(method: .goBack, payload: OwlFreshWebViewWireMessage.emptyPayload())
    }

    public func goForward() throws {
        try write(method: .goForward, payload: OwlFreshWebViewWireMessage.emptyPayload())
    }

    public func reload() throws {
        try write(method: .reload, payload: OwlFreshWebViewWireMessage.emptyPayload())
    }

    public func stopLoading() throws {
        try write(method: .stopLoading, payload: OwlFreshWebViewWireMessage.emptyPayload())
    }

    private func write(method: OwlFreshWebViewWireMessage.Method, payload: Data) throws {
        try writer.writeMessage(
            pipe: remoteHandle,
            data: OwlFreshWebViewWireMessage.message(method: method, payload: payload),
            handles: []
        )
    }
}

public enum OwlFreshWebViewWireMessage {
    public enum Method: UInt32 {
        case navigate = 0
        case resize = 1
        case setFocus = 2
        case goBack = 3
        case goForward = 4
        case reload = 5
        case stopLoading = 6
    }

    public static func message(method: Method, payload: Data) -> Data {
        MojoWireMessage.message(method: method.rawValue, payload: payload)
    }

    public static func navigatePayload(url: String) -> Data {
        let stringData = MojoWireMessage.utf8String(url)
        var data = Data(count: MojoWireMessage.align(16 + stringData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + stringData.count, with: stringData)
        return data
    }

    public static func resizePayload(_ request: OwlFreshWebViewResizeRequest) -> Data {
        var data = Data(count: 24)
        data.writeUInt32(24, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(request.width, at: 8)
        data.writeUInt32(request.height, at: 12)
        data.writeFloat32(request.scale, at: 16)
        return data
    }

    public static func setFocusPayload(_ focused: Bool) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data[8] = focused ? 1 : 0
        return data
    }

    public static func emptyPayload() -> Data {
        var data = Data(count: 8)
        data.writeUInt32(8, at: 0)
        data.writeUInt32(0, at: 4)
        return data
    }

}
