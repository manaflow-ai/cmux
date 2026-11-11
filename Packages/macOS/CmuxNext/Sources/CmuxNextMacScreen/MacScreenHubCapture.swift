#if DEBUG
import AppKit
import CmuxNextCompat
import CmuxNextDevices
import CmuxNextSettings
import CryptoKit
import Foundation

/// DEBUG ONLY, captures of ui-state-fixes M5 (Your Devices on the Mac Screen home page). Each
/// state gives the page's box a real ``DeviceHub`` of its own whose HTTP calls a local
/// ``URLProtocol`` answers (`*.capture.invalid`, nothing leaves this Mac) and whose socket opens
/// only when the capture says so, so the page's real derivation (status, `devicesListed`,
/// `devicesListTimedOut`, the 10 s list deadline) decides what it shows:
/// - `loading`: a hub not started (`idle`).
/// - `failed`: a start whose account read fails (`failed`): the error with Try Again.
/// - `failed_then_hang`: as `failed`, but every later start waits (Try Again: loading again).
/// - `timeout`: registered (`ready`), the socket never connects, so the list is never read: past
///   the deadline the error with Try Again.
/// - `empty`: registered, connected, the list read with no other device: "None of your other
///   devices share Mac Screen…".
/// Then `deliver` lets the held socket (and a held start) go and the list arrives with one shared
/// Mac (data after the deadline replaces the error); `retry` clicks the page's Try Again button;
/// `geometry` reports the failed state's note text and Try Again frames (the 14 pt inset).
@MainActor
enum MacScreenHubCapture {
    /// The gates of the hub the page reads now, opened by `deliver`.
    private static var gates: [CaptureGate] = []

    static func make(_ state: String) async -> DeviceHub? {
        let tokenGate = CaptureGate(open: state != "failed_then_hang")
        let socketGate = CaptureGate(open: state == "empty")
        gates = [tokenGate, socketGate]
        let host: String
        switch state {
        case "loading", "failed", "failed_then_hang", "timeout": host = "late.capture.invalid"
        case "empty": host = "empty.capture.invalid"
        default: return nil
        }
        guard let base = URL(string: "https://\(host)") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHubProtocol.self]
        let session = URLSession(configuration: configuration)
        let calls = CaptureTokenCalls()
        let failsFirst = state == "failed" || state == "failed_then_hang"
        // A start's account read is asked twice (the client asks again once after a refusal): the first start fails both.
        let alwaysFails = state == "failed"
        let tokens = DeviceHubAccountToken {
            let call = calls.next()
            if alwaysFails || (failsFirst && call < 2) { throw DeviceHubError.notSignedIn }
            await tokenGate.opened()
            return "capture"
        }
        let identity = DeviceIdentity(deviceID: UUID(), keys: HubCaptureKeys())
        let client = DeviceHubClient(baseURL: base, identity: identity, tokens: tokens, session: session)
        let socket = DeviceHubSocket(connector: CaptureConnector(gate: socketGate))
        let hub = DeviceHub(client: client, socket: socket, secrets: MemoryRelaySecretStore(), deviceName: "Capture")
        switch state {
        case "loading": break
        case "failed", "failed_then_hang": await hub.start()
        default:
            // task-owner: the capture hub's start; it ends with the registration (the stub answers at once).
            Task { await hub.start() }
        }
        return hub
    }

    /// `deliver`: the held start and socket go on; the list read then names one shared Mac.
    static func deliver(_ hub: DeviceHub?) -> JSONValue {
        for gate in gates { gate.open() }
        CaptureHubProtocol.delivered.value.withLock { $0 = true }
        return ["ok": true, "status": .string(hub.map { "\($0.status)" } ?? "none")]
    }

    /// `retry`: a click on Your Devices' Try Again button, as the person's.
    static func clickRetry() -> JSONValue {
        guard let button = findRetry() as? NSButton else { return ["error": "no Try Again button shown"] }
        button.performClick(nil)
        return ["ok": true]
    }

    /// `geometry`: Try Again and the note text above it, in window points (top-left origin) and
    /// pixels, and the card column they share; the text's first glyph starts 2 pt into its field
    /// (the label cell's padding), measured on the stills too.
    static func geometry() -> JSONValue {
        guard let button = findRetry(), let column = button.superview, let window = button.window,
              let text = column.subviews.first(where: { $0 is NSTextField && !($0 is NSButton) })
        else { return ["error": "no Try Again with its note shown"] }
        let scale = Double(window.backingScaleFactor)
        func frame(_ view: NSView) -> JSONValue {
            let rect = view.convert(view.bounds, to: nil)
            let height = Double(window.contentView?.bounds.height ?? 0)
            let top = height - Double(rect.maxY)
            return ["x": .number(Double(rect.minX)), "y": .number(top), "width": .number(Double(rect.width)),
                    "height": .number(Double(rect.height)), "x_px": .number(Double(rect.minX) * scale),
                    "y_px": .number(top * scale)]
        }
        let insets: JSONValue
        if let stack = column as? NSStackView {
            insets = ["left": .number(Double(stack.edgeInsets.left)), "top": .number(Double(stack.edgeInsets.top)),
                      "spacing": .number(Double(stack.spacing))]
        } else {
            insets = .null
        }
        return ["scale": .number(scale), "button": frame(button), "text": frame(text), "column": frame(column),
                "column_insets": insets, "button_title": .string((button as? NSButton)?.title ?? ""),
                "text_value": .string((text as? NSTextField)?.stringValue ?? "")]
    }

    private static func findRetry() -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "macScreen.home.devicesRetry" { return view }
            for child in view.subviews { if let found = search(child) { return found } }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView, let found = search(content) { return found }
        }
        return nil
    }
}

/// A one-way gate: `opened()` returns once `open()` ran (at once when it was open already).
nonisolated private final class CaptureGate: Sendable {
    private struct State: ~Copyable {
        var isOpen: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(open: Bool) { state = Mutex(State(isOpen: open)) }

    func opened() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// Counts the account reads of one capture hub.
nonisolated private final class CaptureTokenCalls: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock { count in
            defer { count += 1 }
            return count
        }
    }
}

/// The capture hub's socket: it connects once its gate opens, then stays open with no push.
nonisolated private struct CaptureConnector: DeviceHubSocketConnector {
    let gate: CaptureGate

    func connect() async throws -> any DeviceHubSocketConnection {
        await gate.opened()
        return CaptureSocketConnection()
    }
}

nonisolated private final class CaptureSocketConnection: DeviceHubSocketConnection {
    private let closed = CaptureGate(open: false)

    func receive() async throws -> String {
        await closed.opened()
        throw CancellationError()
    }

    func send(_ text: String) async throws {}

    func close() { closed.open() }
}

/// Answers the capture hub's HTTP calls here: the account exchange, the registration, the device
/// list (none on `empty.*`; one shared Mac on `late.*` once delivered) and nothing else (404).
nonisolated private final class CaptureHubProtocol: URLProtocol {
    static let delivered = CaptureFlag()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("capture.invalid") ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        var status = 200
        let body: String
        if method == "POST", path.hasSuffix("/v1/auth/stack") {
            body = #"{"session":"capture","userId":"capture-user"}"#
        } else if method == "POST", path.hasSuffix("/v1/devices") {
            body = #"{"device":{"id":"capture-self","name":"Capture","platform":"macos"}}"#
        } else if method == "GET", path.hasSuffix("/v1/devices") {
            let shared = url.host?.hasPrefix("late.") == true && Self.delivered.value.withLock { $0 }
            body = shared
                ? #"{"devices":[{"id":"studio-mac","name":"Studio Mac","platform":"macos","macScreenShared":true,"online":true}]}"#
                : #"{"devices":[]}"#
        } else {
            status = 404
            body = #"{"error":{"code":"not_found","message":"capture stub"}}"#
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A Bool behind a lock.
nonisolated final class CaptureFlag: Sendable {
    let value = Mutex(false)
}

/// Software P-256 keys for a capture hub (never stored).
nonisolated private struct HubCaptureKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()

    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }

    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }

    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
        throw DeviceHubError.identity("capture keys open nothing")
    }
}
#endif
