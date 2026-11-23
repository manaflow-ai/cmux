public import AppKit
public import OSLog

/// A Cloud machine's desktop stream, watching only: the same `cmux-rd` session Open Desktop's viewer
/// runs, with no chrome and no input. The Chief's computer shows it (the App makes it a
/// `HomeChiefComputerLiveFeed`); the person's input while they hold control still goes through the
/// screen's own route.
public final class RemoteDesktopWatchFeed {
    public static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "chief.computer")
    private let pane: RemoteDesktopPane
    private let transport: RemoteRdStreamTransport
    private let agentActs: () -> Bool
    private var cursor: RemoteCursorState?
    private var lastStatus = ""
    public var onChange: (() -> Void)?

    /// `agentActs` says whether an agent drives the machine now: only then is its pointer drawn.
    public init(name: String, transport: RemoteRdStreamTransport, agentActs: @escaping () -> Bool) {
        self.transport = transport
        self.agentActs = agentActs
        pane = RemoteDesktopPane(hostName: name, source: transport, inputSink: nil, initialMode: .view, scaling: .fit,
                                 viaCloudTunnel: true, modeControl: .takeOver)
        pane.view.showsChrome = false
        pane.onStateChange = { [weak self] in
            guard let self else { return }
            let line = debugStatus
            if line != lastStatus {
                lastStatus = line
                Self.logger.notice("computer live: \(line, privacy: .public)")
            }
            onChange?()
        }
        pane.onCursor = { [weak self] in
            self?.cursor = $0
            self?.onChange?()
        }
        pane.start()
        transport.connect()
    }

    public var debugStatus: String { "\(String(describing: pane.state.status)) hasFrame=\(pane.state.hasFrame) overlay=\(String(describing: pane.state.overlay))" }
    public var view: NSView { pane.view }
    public var isLive: Bool { pane.isShowingFrames }
    public var pixels: CGSize { pane.framePixels }
    /// The agent's pointer in stream pixels; nil while no agent acts or the host hides it.
    public var pointer: CGPoint? {
        guard agentActs(), let cursor, cursor.visible else { return nil }
        return cursor.position
    }

    public func stop() {
        pane.stop()
        transport.stop()
    }
}
