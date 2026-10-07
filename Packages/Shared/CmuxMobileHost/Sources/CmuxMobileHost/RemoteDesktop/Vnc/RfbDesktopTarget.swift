import CmuxBrowserStream
import CmuxRemoteDesktop
import Foundation

/// A VNC server seen through this Mac (c3-rd.md 1): runs the RFB session,
/// keeps the framebuffer, publishes the visible region on every update,
/// and turns rd input into RFB pointer and key events. The phone's password
/// is used once for the DES challenge and never kept.
public actor RfbDesktopTarget: RemoteDesktopTarget {
    public nonisolated let video: any BrowserVideoSource
    public nonisolated var cursor: RemoteDesktopChannelOpened.Cursor { .inVideo }

    private let client: RfbClient
    private let address: VncAddress
    private let source: CapturedVideoSource
    private let capture = RfbFrameCapture()
    private let keysyms = HidKeysymMap()
    private let scaler = RfbFrameScaler()
    private let origin = ContinuousClock.now
    private let eventsStream: AsyncStream<RemoteDesktopTargetEvent>
    private let eventsContinuation: AsyncStream<RemoteDesktopTargetEvent>.Continuation

    private var framebuffer = RfbFramebuffer(width: 0, height: 0)
    private var targetInfo: DesktopTargetInfo
    private var region = DesktopRect(width: 0, height: 0)
    private var buttons: UInt8 = 0
    private var pointer = (x: 0, y: 0)
    private var heldKeys: Set<UInt32> = []
    private var serverText: String?
    private var passwordWaiter: CheckedContinuation<String?, Never>?
    private var running: Task<Void, Never>?
    private var closed = false

    /// `client` has already negotiated the version (the connector checks
    /// that the peer speaks RFB before the session sees a target).
    init(client: RfbClient, address: VncAddress, encoder: any BrowserFrameEncoder) {
        self.client = client
        self.address = address
        let source = CapturedVideoSource(capture: capture, encoder: encoder)
        self.source = source
        video = source
        targetInfo = DesktopTargetInfo(kind: .vnc, width: 0, height: 0, scale: 1, name: address.name ?? address.host)
        (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: RemoteDesktopTargetEvent.self)
    }

    func start() async {
        await capture.setOnConfigure { [weak self] in await self?.publish() }
        running = Task { await self.run() }
    }

    public func info() -> DesktopTargetInfo { targetInfo }

    public func events() -> AsyncStream<RemoteDesktopTargetEvent> { eventsStream }

    // MARK: Session

    private func run() async {
        do {
            try await client.authenticate { [weak self] in await self?.waitForPassword() }
            let server = try await client.initialize()
            framebuffer = RfbFramebuffer(width: server.width, height: server.height)
            resized(width: server.width, height: server.height, name: address.name ?? (server.name.isEmpty ? address.host : server.name))
            eventsContinuation.yield(.live)
            while !closed {
                switch try await client.readMessage() {
                case .update(let rects):
                    var changed = false
                    for rect in rects {
                        let sizeChanged: Bool
                        if case .desktopSize = rect.content { sizeChanged = true } else { sizeChanged = false }
                        changed = framebuffer.apply(rect) || changed
                        if sizeChanged { resized(width: rect.width, height: rect.height, name: targetInfo.name) }
                    }
                    if changed { await publish() }
                    try await client.requestUpdate(incremental: true)
                case .cutText(let text):
                    serverText = text
                    eventsContinuation.yield(.clipboard(text))
                case .bell, .colourMap:
                    break
                }
            }
        } catch RfbError.authFailed, RfbError.passwordMissing {
            finish(.vncAuthFailed)
        } catch {
            finish(.vncClosed)
        }
    }

    private func waitForPassword() async -> String? {
        guard !closed else { return nil }
        eventsContinuation.yield(.authRequired)
        return await withCheckedContinuation { passwordWaiter = $0 }
    }

    private func resized(width: Int, height: Int, name: String) {
        targetInfo = DesktopTargetInfo(kind: .vnc, width: width, height: height, scale: 1, name: name)
        region = DesktopRect(width: width, height: height)
        eventsContinuation.yield(.resized(targetInfo))
    }

    /// Publishes the visible region at the view's pixel size.
    private func publish() async {
        guard let crop = framebuffer.pixelBuffer(region: region) else { return }
        let width = await capture.pixelWidth
        let height = await capture.pixelHeight
        let scaled = scaler.scale(crop, toWidth: width, height: height)
        let elapsed = ContinuousClock.now - origin
        let micros = UInt64(elapsed.components.seconds) * 1_000_000 + UInt64(elapsed.components.attoseconds / 1_000_000_000_000)
        await capture.publish(BrowserCapturedFrame(pixelBuffer: scaled, captureMicros: micros))
    }

    private func finish(_ reason: DesktopEndReason) {
        guard !closed else { return }
        eventsContinuation.yield(.ended(reason))
        eventsContinuation.finish()
    }

    // MARK: RemoteDesktopTarget

    public func setRegion(_ rect: DesktopRect) async throws {
        region = rect
        await publish()
    }

    public func apply(_ event: RdInputEvent) async {
        switch event {
        case .pointer(let x, let y):
            pointer = (Int(x), Int(y))
            try? await client.pointer(mask: buttons, x: pointer.x, y: pointer.y)
        case .button(let button, let down):
            guard (1...8).contains(button) else { return }
            let bit = UInt8(1) << (button - 1)
            buttons = down ? buttons | bit : buttons & ~bit
            try? await client.pointer(mask: buttons, x: pointer.x, y: pointer.y)
        case .scroll(let dx, let dy, _):
            // Wheel buttons 4/5 vertical, 6/7 horizontal; one click per 100 units.
            for (amount, negative, positive) in [(dy, UInt8(4), UInt8(5)), (dx, 6, 7)] {
                let clicks = min(Int(abs(amount)) / 100, 50)
                let bit = UInt8(1) << ((amount < 0 ? negative : positive) - 1)
                for _ in 0..<clicks {
                    try? await client.pointer(mask: buttons | bit, x: pointer.x, y: pointer.y)
                    try? await client.pointer(mask: buttons, x: pointer.x, y: pointer.y)
                }
            }
        case .key(let usage, let down):
            guard let keysym = keysyms.keysym(for: HidUsage(rawValue: usage)) else { return }
            if down { heldKeys.insert(keysym) } else { heldKeys.remove(keysym) }
            try? await client.key(keysym, down: down)
        case .text(let text):
            for keysym in keysyms.keysyms(for: text) {
                try? await client.key(keysym, down: true)
                try? await client.key(keysym, down: false)
            }
        case .service:
            break
        }
    }

    public func pushClipboard(_ text: String) async {
        try? await client.cutText(text)
    }

    public func readClipboard() -> String? { serverText }

    public func authenticate(password: String) {
        passwordWaiter?.resume(returning: password)
        passwordWaiter = nil
    }

    public func close() async {
        guard !closed else { return }
        for keysym in heldKeys { try? await client.key(keysym, down: false) }
        if buttons != 0 { try? await client.pointer(mask: 0, x: pointer.x, y: pointer.y) }
        closed = true
        passwordWaiter?.resume(returning: nil)
        passwordWaiter = nil
        await client.close()
        running?.cancel()
        await source.stop()
        eventsContinuation.finish()
    }
}
