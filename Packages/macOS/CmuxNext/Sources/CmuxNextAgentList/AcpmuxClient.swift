import CAcpmuxClientFFI
public import Foundation
import CmuxNextCompat

/// crash-allow: all mutable state is confined to the private utility queue; C handles never escape it.
public nonisolated final class AcpmuxClient: @unchecked Sendable {
    public struct ReceivedResult: Sendable {
        public let code: Int32
        public let consumed: Int

        public var isSuccess: Bool { code == 0 }
    }

    public static let expectedABIVersion = UInt32(ACPMUX_CLIENT_ABI_VERSION)
    /// The ABI's code for a request the core refused (`ACPMUX_CLIENT_ERR_INVALID`).
    public static let refusedCode = Int32(ACPMUX_CLIENT_ERR_INVALID)
    private let queue = DispatchQueue(label: "cmux.acpmux-client", qos: .utility) // qos-allow: serialized C calls are background transport work
    private var handle: UnsafeMutableRawPointer?
    private var sendHandler: (@Sendable (Data) -> Void)?
    public let isAvailable: Bool

    public init(surfaces: [String] = ["list"]) {
        guard acpmux_client_abi_version() == Self.expectedABIVersion else {
            isAvailable = false
            return
        }
        if surfaces == ["list"] {
            handle = acpmux_client_new()
        } else {
            let data = (try? JSONSerialization.data(withJSONObject: surfaces)) ?? Data("[\"list\"]".utf8)
            handle = data.withUnsafeBytes { raw in
                acpmux_client_new_with_surfaces(raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
        isAvailable = handle != nil
    }

    nonisolated deinit {
        queue.blockingSync { if let handle { acpmux_client_free(handle); self.handle = nil } }
    }

    @discardableResult public func connected() -> Int32 {
        queue.blockingSync {
            guard let handle else { return -3 }
            let code = acpmux_client_connected(handle)
            flushSend()
            return code
        }
    }
    @discardableResult public func disconnected() -> Int32 {
        queue.blockingSync {
            guard let handle else { return -3 }
            let code = acpmux_client_disconnected(handle)
            flushSend()
            return code
        }
    }

    public func received(_ data: Data) -> ReceivedResult {
        queue.blockingSync {
            guard let handle else { return ReceivedResult(code: -3, consumed: 0) }
            var consumed = 0
            let result = data.withUnsafeBytes { raw in
                acpmux_client_received(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count, &consumed)
            }
            flushSend()
            return ReceivedResult(code: result, consumed: consumed)
        }
    }

    public func takeSend() -> Data? {
        queue.blockingSync { guard let handle else { return nil }; return take { acpmux_client_take_send(handle, $0) } }
    }
    public func nextChange() -> Data? {
        queue.blockingSync {
            guard let handle else { return nil }
            let result = take { acpmux_client_next_change(handle, $0) }
            flushSend()
            return result
        }
    }

    public func setSendHandler(_ handler: (@Sendable (Data) -> Void)?) {
        queue.blockingSync {
            sendHandler = handler
            flushSend()
        }
    }

    public func subscribe(_ request: Data) -> Data? { call(request) { handle, p, n, out in acpmux_client_subscribe(handle, p, n, out) } }
    public func subscribeMirror(_ request: Data) -> Data? { call(request) { handle, p, n, out in acpmux_client_subscribe_mirror(handle, p, n, out) } }
    @discardableResult public func want(_ request: Data) -> Int32 { mutate(request) { handle, p, n in acpmux_client_want(handle, p, n) } }
    @discardableResult public func unwant(_ request: Data) -> Int32 { mutate(request) { handle, p, n in acpmux_client_unwant(handle, p, n) } }
    @discardableResult public func unsubscribe(_ request: Data) -> Int32 { mutate(request) { handle, p, n in acpmux_client_unsubscribe(handle, p, n) } }
    @discardableResult public func page(_ request: Data) -> Int32 { mutate(request) { handle, p, n in acpmux_client_page(handle, p, n) } }
    public func subscribeChat(_ request: Data) -> Data? { call(request) { handle, p, n, out in acpmux_client_subscribe_chat(handle, p, n, out) } }
    /// ``subscribeChat(_:)``'s ABI code: 0 when the core took the sub, ``refusedCode`` when it
    /// refused the request, and another code for no handle or a panic in the core.
    public func subscribeChatCode(_ request: Data) -> Int32 {
        coded(request) { handle, p, n, out in acpmux_client_subscribe_chat(handle, p, n, out) }.code
    }
    @discardableResult public func chatPage(_ request: Data) -> Int32 { mutate(request) { handle, p, n in acpmux_client_chat_page(handle, p, n) } }
    public func chatBlob(_ request: Data) -> Data? { call(request) { handle, p, n, out in acpmux_client_chat_blob(handle, p, n, out) } }

    private func take(_ invoke: (UnsafeMutablePointer<AcpmuxClientBytes>) -> Int32) -> Data? {
        var bytes = AcpmuxClientBytes(ptr: nil, len: 0)
        guard invoke(&bytes) == 0 else { return nil }
        defer { acpmux_client_bytes_free(bytes) }
        guard bytes.len > 0, let ptr = bytes.ptr else { return nil }
        return Data(bytes: ptr, count: bytes.len)
    }

    private func call(_ request: Data, _ invoke: (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<AcpmuxClientBytes>) -> Int32) -> Data? {
        coded(request, invoke).response
    }

    private func coded(_ request: Data, _ invoke: (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<AcpmuxClientBytes>) -> Int32) -> (response: Data?, code: Int32) {
        queue.blockingSync {
            guard let handle else { return (nil, Int32(ACPMUX_CLIENT_ERR_UNKNOWN)) }
            return request.withUnsafeBytes { raw in
                var bytes = AcpmuxClientBytes(ptr: nil, len: 0)
                let result = invoke(handle, raw.bindMemory(to: UInt8.self).baseAddress, request.count, &bytes)
                let response: Data?
                if result == 0 {
                    defer { acpmux_client_bytes_free(bytes) }
                    if let ptr = bytes.ptr, bytes.len > 0 {
                        response = Data(bytes: ptr, count: bytes.len)
                    } else {
                        response = nil
                    }
                } else {
                    response = nil
                }
                flushSend()
                return (response, result)
            }
        }
    }

    private func mutate(_ request: Data, _ invoke: (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int) -> Int32) -> Int32 {
        queue.blockingSync {
            guard let handle else { return -3 }
            let code = request.withUnsafeBytes { raw in invoke(handle, raw.bindMemory(to: UInt8.self).baseAddress, request.count) }
            flushSend()
            return code
        }
    }

    private func flushSend() {
        guard let handle, let sendHandler else { return }
        while let bytes = take { acpmux_client_take_send(handle, $0) } {
            sendHandler(bytes)
        }
    }
}
