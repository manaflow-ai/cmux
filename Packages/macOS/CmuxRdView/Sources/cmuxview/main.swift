// cmuxview: one cmux.rd/1 stream, full screen, presented with the cmux NEXT app's own pipeline.
//
//   cmuxview --addr HOST:PORT --token-file PATH [--user NAME]   direct stream carrier to `cmux-rd host`
//   cmuxview --unix PATH                                         the socket of a `cmux rd connect` link bridge
//   common: [--mode view|control] [--presenter metal|layer] [--screen N]
//
// Wiring only, mirroring the app:
// - carrier: RemoteRdStreamCarrier over an NWConnection (MacScreenUnixStream.open for --unix; the same
//   with a TCP endpoint for --addr),
// - transport: RemoteRdStreamTransport (hello and start; MacScreenSession.attachTransport's hello for --unix,
//   RemoteViewDebugRdHost's token hello for --addr), a keyframe asked on the first `streaming` status,
// - decode: RemoteDecodePipeline(source: transport) -> RemoteFramePresenters().make(.metal) (MacScreenPane.decode),
// - layout: the presenter's layer at RemoteViewGeometry(scaling: .fit).imageRect (RemoteVideoView.layout).
// Status lines go to stderr as JSON ({"cmuxview": ...}); the first presented frame is logged once.
// SIGTERM or SIGINT sends stop to the host and exits.

import AppKit
import CmuxNextRemoteView
import Foundation
import Network

struct Options {
    var addr: (host: String, port: UInt16)?
    var unix: String?
    var tokenFile: String?
    var user = NSUserName()
    var control = false
    var presenter = RemotePresenterKind.metal
    var screen: Int?

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.makeIterator()
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("missing value for \(flag)") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--addr":
                let v = value(a)
                guard let colon = v.lastIndex(of: ":"), let port = UInt16(v[v.index(after: colon)...]) else { fail("--addr HOST:PORT") }
                o.addr = (String(v[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port)
            case "--unix": o.unix = value(a)
            case "--token-file": o.tokenFile = value(a)
            case "--user": o.user = value(a)
            case "--mode": o.control = value(a) == "control"
            case "--presenter": o.presenter = value(a) == "layer" ? .layerContents : .metal
            case "--screen": o.screen = Int(value(a))
            case "-h", "--help":
                FileHandle.standardError.write(Data("usage: cmuxview (--addr HOST:PORT --token-file PATH [--user NAME] | --unix PATH) [--mode view|control] [--presenter metal|layer] [--screen N]\n".utf8))
                exit(0)
            default: fail("unknown argument \(a)")
            }
        }
        if (o.addr == nil) == (o.unix == nil) { fail("give exactly one of --addr or --unix") }
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cmuxview: \(message)\n".utf8))
    exit(2)
}

func log(_ fields: [String: Any]) {
    var line = fields
    line["t_wall_ms"] = Date().timeIntervalSince1970 * 1000
    guard let data = try? JSONSerialization.data(withJSONObject: ["cmuxview": line], options: [.sortedKeys]) else { return }
    FileHandle.standardError.write(data + Data("\n".utf8))
}

/// A one-shot latch for a continuation resumed from NWConnection's state handler.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// An NWConnection as the transport's byte stream (MacScreenUnixStream.open, any endpoint).
func openStream(_ endpoint: NWEndpoint, _ parameters: NWParameters) async throws -> RemoteRdByteStream {
    let connection = NWConnection(to: endpoint, using: parameters)
    let queue = DispatchQueue(label: "cmuxview.rd-socket", qos: .userInitiated)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let once = Once()
        connection.stateUpdateHandler = { state in
            let resume: (Result<Void, any Error>) -> Void = { result in
                if once.take() { continuation.resume(with: result) }
            }
            switch state {
            case .ready: resume(.success(()))
            case let .failed(error), let .waiting(error): resume(.failure(error))
            case .cancelled: resume(.failure(CancellationError()))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    return RemoteRdByteStream(
        read: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 } ?? (isComplete || error != nil ? nil : Data()))
                }
            }
        },
        write: { bytes in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        },
        close: { connection.cancel() }
    )
}

/// Hosts the presenter's layer at the fitted image rect (RemoteVideoView's layout, `.fit`).
final class VideoHostView: NSView {
    let presenter: any RemoteFramePresenter
    var framePixels: CGSize = .zero { didSet { needsLayout = true } }

    init(presenter: any RemoteFramePresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.insertSublayer(presenter.layer, at: 0)
        presenter.layer.contentsGravity = .resize
        presenter.layer.minificationFilter = .trilinear
        presenter.layer.magnificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        presenter.setBackingScale(backingScale)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if framePixels.width > 0, framePixels.height > 0 {
            let geometry = RemoteViewGeometry(framePixels: framePixels, bounds: bounds, backingScale: backingScale, scaling: .fit)
            presenter.layer.frame = geometry.imageRect
            presenter.layer.isHidden = false
        } else {
            presenter.layer.isHidden = true
        }
        CATransaction.commit()
    }
}

@MainActor
final class Viewer: NSObject, NSApplicationDelegate {
    let options: Options
    var window: NSWindow?
    var video: VideoHostView?
    var transport: RemoteRdStreamTransport?
    var tasks: [Task<Void, Never>] = []
    var signals: [DispatchSourceSignal] = []

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screens = NSScreen.screens
        let screen = options.screen.flatMap { $0 < screens.count ? screens[$0] : nil } ?? NSScreen.main ?? screens[0]
        let presenter = RemoteFramePresenters().make(options.presenter)
        let video = VideoHostView(presenter: presenter)
        self.video = video
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.contentView = video
        window.setFrame(screen.frame, display: true)
        self.window = window
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        presenter.setBackingScale(window.backingScaleFactor)
        presenter.onFrameSize = { [weak video] size in
            video?.framePixels = size
            log(["frame_size": [Int(size.width), Int(size.height)]])
        }
        installSignals()
        start(presenter: presenter)
    }

    private func start(presenter: any RemoteFramePresenter) {
        let carrier: RemoteRdStreamCarrier
        let hello: RemoteRdHello
        if let path = options.unix {
            carrier = RemoteRdStreamCarrier(open: { try await openStream(.unix(path: path), .tcp) })
            // MacScreenSession.attachTransport: the link admitted the viewer; the host does not read these claims.
            hello = RemoteRdHello(user: "viewer", install: "mac-screen", maxDatagram: 1126, token: nil)
        } else if let addr = options.addr {
            let token: String?
            if let file = options.tokenFile {
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("cannot read --token-file") }
                token = text.split(whereSeparator: \.isNewline).first.map(String.init)
            } else {
                token = nil // the Windows host takes no token
            }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(addr.host), port: NWEndpoint.Port(rawValue: addr.port)!)
            carrier = RemoteRdStreamCarrier(open: { try await openStream(endpoint, parameters) })
            hello = RemoteRdHello(user: options.user, install: "cmuxview-\(ProcessInfo.processInfo.processIdentifier)", token: token)
        } else {
            fail("no endpoint")
        }
        guard let transport = RemoteRdStreamTransport(carrier: carrier, hello: hello, startKey: UUID().uuidString, control: options.control) else {
            fail("the rd core could not allocate")
        }
        self.transport = transport
        let firstFrame = Once()
        let deliver: @Sendable (RemoteDecodedFrame) -> Void = { frame in
            presenter.present(frame)
            if firstFrame.take() { log(["first_frame": frame.frame, "size": [Int(frame.pixelSize.width), Int(frame.pixelSize.height)]]) }
        }
        let pipeline = RemoteDecodePipeline(source: transport, deliver: deliver)
        tasks.append(Task.detached(priority: .userInitiated) { await pipeline.run() })
        let statuses = transport.statusUpdates()
        tasks.append(Task { @MainActor in
            var askedKeyframe = false
            for await status in statuses {
                switch status.state {
                case .connecting:
                    log(["state": "connecting", "detail": status.connectingReason ?? ""])
                case .waitingForConsent:
                    log(["state": "waiting_for_consent"])
                case .streaming:
                    if !askedKeyframe {
                        askedKeyframe = true
                        transport.requestKeyframe()
                        log(["state": "streaming"])
                    }
                case let .ended(why):
                    let stats = await pipeline.stats
                    log(["state": "ended", "why": String(describing: why), "reason": status.endReason ?? "",
                         "decoded": stats.decoded, "gaps": stats.gaps, "decode_errors": stats.decodeErrors,
                         "keyframe_requests": stats.keyframeRequests, "hardware": stats.hardware])
                    exit(why == .stoppedByViewer ? 0 : 3)
                }
            }
        })
        log(["state": "connect", "carrier": options.unix != nil ? "unix" : "tcp"])
        transport.connect()
    }

    private func installSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                log(["state": "stopping", "signal": sig])
                self?.transport?.stop()
                // The host answers ended (the status task exits 0); exit anyway if it does not within 1 s.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
            }
            source.resume()
            signals.append(source)
        }
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.regular)
// main.swift's top level runs on the main thread; the delegate is weak, so the viewer lives through run().
MainActor.assumeIsolated {
    let viewer = Viewer(options: options)
    app.delegate = viewer
    withExtendedLifetime(viewer) { app.run() }
}
