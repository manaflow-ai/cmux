import CmuxNextRemoteView
import CmuxScreenKit
import CoreGraphics

/// Platform glue for Rust's permitted retry. The original ticket keeps one reader;
/// its already authenticated signals are forwarded to the existing WebRTC client.
@MainActor
final class MacScreenFallback {
    let session: ScreenSession
    private let signals: AsyncThrowingStream<ScreenSignal, any Error>.Continuation
    private var scroll = MacScreenScroll()
    private var initialDisplay: Int?

    init(title: String, preferences: ScreenPreferences, signaling: any ScreenSignaling,
         relayOnly: Bool, refresh: Int?, display: Int?) {
        initialDisplay = display
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self,
            throwing: (any Error).self, bufferingPolicy: .bufferingOldest(512))
        signals = continuation
        let forwarded = MacScreenForwardedSignaling(base: signaling, stream: stream)
        session = ScreenSession(title: title, preferences: preferences, signaling: { forwarded })
        session.reconnectLimit = 0
        session.relayOnly = relayOnly
        session.displayMaximumFrameRate = refresh
    }

    func start() {
        // The authenticated rd session already established that the approved peer is present.
        signals.yield(.hello(peerPresent: true))
        session.connect()
    }

    func forward(_ signal: ScreenSignal) {
        if case .dropped = signals.yield(signal) { finish(RFBError.connectionClosed) }
    }

    func finish(_ error: (any Error)? = nil) { signals.finish(throwing: error) }

    func receivedDisplays(_ sizes: [CGSize], current: Int) {
        guard let display = initialDisplay else { return }
        initialDisplay = nil
        if sizes.indices.contains(display), display != current { session.selectDisplay(display) }
    }

    func close() {
        signals.finish()
        session.disconnect(silently: true)
    }

    func send(_ event: RemoteInputEvent) {
        switch event {
        case let .key(usage, down):
            if let key = VNCKeysym(hidUsage: usage) { session.key(key, down: down) }
        case let .pointer(x, y): session.movePointer(to: CGPoint(x: Int(x), y: Int(y)))
        case let .button(button, down):
            switch button {
            case .left: session.press(.left, down: down)
            case .middle: session.press(.middle, down: down)
            case .right: session.press(.right, down: down)
            case .back, .forward: break
            }
        case let .scroll(dx, dy, precise):
            let lines = scroll.add(dx: dx, dy: dy, precise: precise)
            session.scroll(dx: lines.dx, dy: lines.dy)
        case let .text(text): session.type(text)
        }
    }
}
