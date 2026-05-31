#if canImport(UIKit)
import CMUXMobileCore
import GhosttyKit
import OSLog
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.surface")

enum TerminalInputDebugLog {
    private static let isEnabled = ProcessInfo.processInfo.environment["CMUX_INPUT_DEBUG"] == "1"

    static func log(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #endif
        guard isEnabled else { return }
        TerminalSidebarStore.debugLog("input: \(message)")
    }

    static func textSummary(_ text: String) -> String {
        let summary = String(reflecting: text)
        guard summary.count > 96 else { return summary }
        return "\(summary.prefix(96))..."
    }

    static func dataSummary(_ data: Data) -> String {
        let prefix = data.prefix(32)
        let prefixData = Data(prefix)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let utf8 = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
        let suffix = data.count > prefix.count ? " ..." : ""
        return "len=\(data.count) hex=\(hex)\(suffix) utf8=\(textSummary(utf8))"
    }
}

@MainActor
public protocol GhosttySurfaceViewDelegate: AnyObject {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data)
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize)
}

@MainActor
protocol TerminalSurfaceHosting: AnyObject {
    var currentGridSize: TerminalGridSize { get }
    func processOutput(_ data: Data)
    func focusInput()
    func updateRemotePlatform(_ platform: RemotePlatform)
    /// Apply the daemon's authoritative rendering grid. Unconditional —
    /// implementations render at exactly cols × rows and letterbox any
    /// remaining container area. The daemon broadcasts this on every
    /// attach/resize/detach/open, plus inlined in RPC responses, so
    /// every attached device converges on the same grid.
    func applyViewSize(cols: Int, rows: Int)
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? { get set }
    func accessibilityRenderedTextForTesting() -> String?
    #endif
}

extension TerminalSurfaceHosting {
    func focusInput() {}
    func updateRemotePlatform(_ platform: RemotePlatform) {}
    func applyViewSize(cols _: Int, rows _: Int) {}
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? {
        get { nil }
        set {}
    }
    func accessibilityRenderedTextForTesting() -> String? { nil }
    #endif
}

/// Bridges libghostty C callbacks (which run on the IO read thread or
/// other Ghostty-internal threads) onto the main actor where the
/// `GhosttySurfaceView` lives. The single mutable property is the
/// `weak var surfaceView`; we serialise reads/writes through the main
/// actor, which lets us conform to `Sendable` for the `Task { @MainActor }`
/// hops below.
final class GhosttySurfaceBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var _surfaceView: GhosttySurfaceView?

    var surfaceView: GhosttySurfaceView? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _surfaceView
        }
        set {
            lock.lock()
            _surfaceView = newValue
            lock.unlock()
        }
    }

    func attach(to surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView
    }

    func detach() {
        surfaceView = nil
    }

    func handleWrite(_ bytes: Data) {
        Task { @MainActor [weak self] in
            guard let surfaceView = self?.surfaceView else { return }
            surfaceView.handleOutboundBytes(bytes)
        }
    }

    func handleCloseSurface(processAlive: Bool) {
        Task { @MainActor [weak self] in
            guard let surfaceView = self?.surfaceView else { return }
            NotificationCenter.default.post(
                name: .ghosttySurfaceDidRequestClose,
                object: surfaceView,
                userInfo: ["process_alive": processAlive]
            )
        }
    }

    static func fromOpaque(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceBridge? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    }
}

private enum GhosttySurfaceDisposer {
    static let queue = DispatchQueue(label: "GhosttySurfaceDisposer.queue")

    static func dispose(surface: ghostty_surface_t, bridge: GhosttySurfaceBridge) {
        let retainedBridge = Unmanaged.passRetained(bridge)
        queue.async {
            ghostty_surface_free(surface)
            retainedBridge.release()
        }
    }
}

struct TerminalTextInputPipeline {
    struct Result: Equatable {
        var committedText: String?
        var nextBufferText: String
    }

    static func process(text: String, isComposing: Bool) -> Result {
        guard !isComposing else {
            return Result(committedText: nil, nextBufferText: text)
        }
        guard !text.isEmpty else {
            return Result(committedText: nil, nextBufferText: "")
        }
        return Result(committedText: text, nextBufferText: "")
    }
}

struct TerminalCursorBlinkState: Equatable {
    static let interval: CFTimeInterval = 0.5

    private(set) var isVisible = true
    private var lastToggle: CFTimeInterval = 0

    mutating func start(now: CFTimeInterval) {
        isVisible = true
        lastToggle = now
    }

    mutating func reset(now: CFTimeInterval) {
        isVisible = true
        lastToggle = now
    }

    mutating func advance(now: CFTimeInterval) -> Bool {
        let elapsed = now - lastToggle
        guard elapsed >= Self.interval else { return false }
        let intervals = max(1, Int(elapsed / Self.interval))
        if intervals % 2 == 1 {
            isVisible.toggle()
        }
        lastToggle += CFTimeInterval(intervals) * Self.interval
        return true
    }
}

struct TerminalHardwareKeyCommand: Sendable {
    let input: String
    let modifierFlags: UIKeyModifierFlags
}

enum TerminalHardwareKeyResolver {
    private static let supportedModifierFlags: UIKeyModifierFlags = [.shift, .control, .alternate]
    private static let keyCommands: [TerminalHardwareKeyCommand] = {
        let navigation = [
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputEnd, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: []),
            TerminalHardwareKeyCommand(input: "\t", modifierFlags: []),
            TerminalHardwareKeyCommand(input: "\t", modifierFlags: [.shift]),
        ]
        let controlInputs = Array("abcdefghijklmnopqrstuvwxyz[]\\ 234567/").map(String.init)
            .map { TerminalHardwareKeyCommand(input: $0, modifierFlags: [.control]) }
        let shiftedControlInputs = Array("@^_?").map(String.init)
            .map { TerminalHardwareKeyCommand(input: $0, modifierFlags: [.control, .shift]) }
        return navigation + controlInputs + shiftedControlInputs
    }()

    static func makeKeyCommands(target: Any, action: Selector) -> [UIKeyCommand] {
        keyCommands.map { command in
            UIKeyCommand(
                input: command.input,
                modifierFlags: command.modifierFlags,
                action: action
            )
        }
    }

    static func data(input: String, modifierFlags: UIKeyModifierFlags) -> Data? {
        let normalizedFlags = modifierFlags.intersection(supportedModifierFlags)

        switch (input, normalizedFlags) {
        case (UIKeyCommand.inputLeftArrow, [.alternate]):
            return Data([0x1B, 0x62])
        case (UIKeyCommand.inputRightArrow, [.alternate]):
            return Data([0x1B, 0x66])
        case (UIKeyCommand.inputUpArrow, []):
            return Data([0x1B, 0x5B, 0x41])
        case (UIKeyCommand.inputDownArrow, []):
            return Data([0x1B, 0x5B, 0x42])
        case (UIKeyCommand.inputRightArrow, []):
            return Data([0x1B, 0x5B, 0x43])
        case (UIKeyCommand.inputLeftArrow, []):
            return Data([0x1B, 0x5B, 0x44])
        case (UIKeyCommand.inputHome, []):
            return Data([0x1B, 0x5B, 0x48])
        case (UIKeyCommand.inputEnd, []):
            return Data([0x1B, 0x5B, 0x46])
        case (UIKeyCommand.inputPageUp, []):
            return Data([0x1B, 0x5B, 0x35, 0x7E])
        case (UIKeyCommand.inputPageDown, []):
            return Data([0x1B, 0x5B, 0x36, 0x7E])
        case (UIKeyCommand.inputDelete, []):
            return Data([0x1B, 0x5B, 0x33, 0x7E])
        case (UIKeyCommand.inputDelete, [.alternate]):
            return Data([0x1B, 0x7F])
        case (UIKeyCommand.inputEscape, []):
            return Data([0x1B])
        case ("\t", []):
            return Data([0x09])
        case ("\t", [.shift]):
            return Data([0x1B, 0x5B, 0x5A])
        case let (input, flags) where flags == [.control] || flags == [.control, .shift]:
            return controlCharacter(for: input)
        default:
            return nil
        }
    }

    private static func controlCharacter(for input: String) -> Data? {
        switch input {
        case " ":
            return Data([0x00])
        case "2":
            return Data([0x00])
        case "3":
            return Data([0x1B])
        case "4":
            return Data([0x1C])
        case "5":
            return Data([0x1D])
        case "6":
            return Data([0x1E])
        case "7":
            return Data([0x1F])
        case "/":
            return Data([0x1F])
        case "?":
            return Data([0x7F])
        default:
            break
        }

        guard let scalar = input.uppercased().unicodeScalars.first,
              input.unicodeScalars.count == 1 else { return nil }

        guard (0x40...0x5F).contains(scalar.value) else { return nil }
        return Data([UInt8(scalar.value & 0x1F)])
    }
}

enum TerminalFontZoomDirection: Equatable {
    case decrease
    case increase

    var bindingAction: String {
        switch self {
        case .decrease:
            return "decrease_font_size:1"
        case .increase:
            return "increase_font_size:1"
        }
    }
}

public enum TerminalInputAccessoryAction: Int, CaseIterable {
    case control
    case alternate
    case command
    case shift
    case zoomOut
    case zoomIn
    case escape
    case tab
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case claude
    case codex
    case tilde
    case pipe
    case dollar
    case slash
    case atSign
    case ctrlC
    case ctrlD
    case ctrlZ
    case ctrlL
    case home
    case end
    case pageUp
    case pageDown
    var title: String {
        title(isMacRemote: false)
    }

    func title(isMacRemote: Bool) -> String {
        switch self {
        case .control:
            return isMacRemote ? "⌃" : "Ctrl"
        case .alternate:
            return isMacRemote ? "⌥" : "Alt"
        case .command:
            return "⌘"
        case .shift:
            return "⇧"
        case .zoomOut:
            return ""
        case .zoomIn:
            return ""
        case .escape:
            return "Esc"
        case .tab:
            return "Tab"
        case .ctrlC:
            return "^C"
        case .ctrlD:
            return "^D"
        case .ctrlZ:
            return "^Z"
        case .ctrlL:
            return "^L"
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        case .leftArrow:
            return "←"
        case .rightArrow:
            return "→"
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .home:
            return "Home"
        case .end:
            return "End"
        case .pageUp:
            return "PgUp"
        case .tilde:
            return "~"
        case .pipe:
            return "|"
        case .dollar:
            return "$"
        case .slash:
            return "/"
        case .atSign:
            return "@"
        case .pageDown:
            return "PgDn"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .control: return "terminal.inputAccessory.control"
        case .alternate: return "terminal.inputAccessory.alt"
        case .command: return "terminal.inputAccessory.command"
        case .shift: return "terminal.inputAccessory.shift"
        case .zoomOut: return "terminal.inputAccessory.zoomOut"
        case .zoomIn: return "terminal.inputAccessory.zoomIn"
        case .escape: return "terminal.inputAccessory.escape"
        case .tab: return "terminal.inputAccessory.tab"
        case .upArrow: return "terminal.inputAccessory.up"
        case .downArrow: return "terminal.inputAccessory.down"
        case .leftArrow: return "terminal.inputAccessory.left"
        case .rightArrow: return "terminal.inputAccessory.right"
        case .claude: return "terminal.inputAccessory.claude"
        case .codex: return "terminal.inputAccessory.codex"
        case .tilde: return "terminal.inputAccessory.tilde"
        case .pipe: return "terminal.inputAccessory.pipe"
        case .dollar: return "terminal.inputAccessory.dollar"
        case .slash: return "terminal.inputAccessory.slash"
        case .atSign: return "terminal.inputAccessory.atSign"
        case .ctrlC: return "terminal.inputAccessory.ctrlC"
        case .ctrlD: return "terminal.inputAccessory.ctrlD"
        case .ctrlZ: return "terminal.inputAccessory.ctrlZ"
        case .ctrlL: return "terminal.inputAccessory.ctrlL"
        case .home: return "terminal.inputAccessory.home"
        case .end: return "terminal.inputAccessory.end"
        case .pageUp: return "terminal.inputAccessory.pageUp"
        case .pageDown: return "terminal.inputAccessory.pageDown"
        }
    }

    var accessibilityLabel: String? {
        switch self {
        case .zoomOut:
            return String(localized: "terminal.input_accessory.zoom_out", defaultValue: "Zoom Out")
        case .zoomIn:
            return String(localized: "terminal.input_accessory.zoom_in", defaultValue: "Zoom In")
        default:
            return nil
        }
    }

    var symbolName: String? {
        switch self {
        case .zoomOut:
            return "minus.magnifyingglass"
        case .zoomIn:
            return "plus.magnifyingglass"
        default:
            return nil
        }
    }

    var zoomDirection: TerminalFontZoomDirection? {
        switch self {
        case .zoomOut:
            return .decrease
        case .zoomIn:
            return .increase
        default:
            return nil
        }
    }

    /// Whether this action is a modifier key (toggleable armed state).
    var isModifier: Bool {
        switch self {
        case .control, .alternate, .command, .shift: return true
        default: return false
        }
    }

    var output: Data? {
        switch self {
        case .control, .alternate, .command, .shift, .zoomOut, .zoomIn:
            return nil
        case .escape:
            return Data([0x1B])
        case .tab:
            return Data([0x09])
        case .tilde:
            return Data([0x7E]) // ~
        case .pipe:
            return Data([0x7C]) // |
        case .dollar:
            return Data([0x24]) // $
        case .slash:
            return Data([0x2F]) // /
        case .atSign:
            return Data([0x40]) // @
        case .ctrlC:
            return Data([0x03])
        case .ctrlD:
            return Data([0x04])
        case .ctrlZ:
            return Data([0x1A])
        case .ctrlL:
            return Data([0x0C])
        case .upArrow:
            return Data([0x1B, 0x5B, 0x41]) // ESC[A
        case .downArrow:
            return Data([0x1B, 0x5B, 0x42]) // ESC[B
        case .leftArrow:
            return Data([0x1B, 0x5B, 0x44]) // ESC[D
        case .rightArrow:
            return Data([0x1B, 0x5B, 0x43]) // ESC[C
        case .claude:
            return Data("claude --dangerously-skip-permissions\r".utf8)
        case .codex:
            return Data("codex --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort=xhigh --search\r".utf8)
        case .home:
            return Data([0x1B, 0x5B, 0x48]) // ESC[H
        case .end:
            return Data([0x1B, 0x5B, 0x46]) // ESC[F
        case .pageUp:
            return Data([0x1B, 0x5B, 0x35, 0x7E]) // ESC[5~
        case .pageDown:
            return Data([0x1B, 0x5B, 0x36, 0x7E]) // ESC[6~
        }
    }
}

public final class GhosttySurfaceView: UIView, TerminalSurfaceHosting {
    private weak var runtime: GhosttyRuntime?
    private weak var delegate: GhosttySurfaceViewDelegate?
    private let fontSize: Float32
    /// Surface-owned live font size (points). Zoom mutates this; it is the
    /// source of truth for the current size, so the size accumulates correctly
    /// across taps even though the actual libghostty apply is coalesced.
    private var liveFontSize: Float32
    /// Latest zoom target awaiting a coalesced apply. The display link applies
    /// it once per frame via an absolute `set_font_size` so a burst of zoom
    /// taps becomes one libghostty push + resize per frame, instead of one per
    /// tap. That keeps the serial `outputQueue` from accumulating blocking
    /// pushes (mailbox `.forever` push / swap-chain wait) faster than the
    /// per-frame render drains them — the wedge that froze zoom.
    private var pendingFontSize: Float32?
    /// Countdown of quiet frames before the post-zoom geometry resync fires.
    /// A zoom step changes the cell size, which (when letterbox-pinned to the
    /// Mac's grid) changes `renderRect` and so reallocates the IOSurface render
    /// target. Doing that every step thrashed the GPU and wedged
    /// `render_now`'s synchronous frame wait. Instead each step only applies
    /// the font (the grid reflows inside the current surface) and arms this
    /// counter; the display link runs ONE `setNeedsGeometrySync` once zoom goes
    /// quiet, so the letterbox re-pins a single time. nil = nothing pending.
    private var zoomSettleFrames: Int?
    private static let zoomSettleFrameThreshold = 6
    private let bridge = GhosttySurfaceBridge()
    private let prefersSnapshotFallbackRendering = false
    var onFocusInputRequestedForTesting: (() -> Void)?
    private var surfaceTitle: String?
    private var displayLink: CADisplayLink?
    private var cursorBlinkState = TerminalCursorBlinkState()
    private var cursorOverlayLayer: CALayer?
    private var needsDraw: Bool = false
    /// Countdown of extra draw requests after a geometry change, so the
    /// renderer (which presents a frame behind) produces a frame at the final
    /// settled layer size rather than leaving a stale mid-animation surface.
    /// Bounded to avoid a perpetual main-queue present flood.
    private var pendingRenderFrames: Int = 0
    /// At most one `render_now` is in flight on `outputQueue` at a time. The
    /// display link can fire at 120Hz and previously enqueued a render every
    /// frame with no guard, so during a continuous pinch renders piled up
    /// faster than the serial queue drained them. Each op stayed fast, but the
    /// DISPLAYED frame fell seconds behind the live font and only caught up
    /// when zoom stopped and the backlog drained — the "frozen, no updates"
    /// symptom. Coalescing caps the backlog: while a render is in flight, mark
    /// `needsAnotherRender` and re-enqueue exactly one when it completes.
    private var renderInFlight: Bool = false
    private var needsAnotherRender: Bool = false
    /// Set by any geometry trigger (resize/zoom/keyboard/effective-grid pin);
    /// the display link applies geometry at most once per frame. Coalescing
    /// prevents the fast-zoom geometry storm that thrashed the grid (jumbled
    /// rendering) and saturated the renderer.
    private var needsGeometrySync: Bool = false
    private var pendingGeometryReassert: Bool = false
    /// Last content scale pushed to libghostty; used to skip redundant
    /// per-frame `set_content_scale` pushes (the screen scale is constant).
    private var lastAppliedContentScale: CGFloat = 0
    private var surfaceHasReceivedOutput: Bool = false
    private var shouldScrollInitialOutputToBottom = true
    /// Serial background queue for `ghostty_surface_process_output`, which
    /// blocks on libghostty's internal renderer/IO futex. Running it on the
    /// main thread hangs the app until the scene-update watchdog kills it.
    private static let outputQueue = DispatchQueue(
        label: "dev.cmux.GhosttySurfaceView.output",
        qos: .userInitiated
    )
    #if DEBUG
    private var lastInputTimestamp: CFTimeInterval = 0
    private var latencySamples: [Double] = []
    var onOutputProcessedForTesting: (() -> Void)?
    #endif
    private let snapshotFallbackView: UITextView = {
        let view = UITextView()
        view.backgroundColor = UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0, alpha: 1)
        view.textColor = UIColor(red: 0xfd/255.0, green: 0xff/255.0, blue: 0xf1/255.0, alpha: 1)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.textContainer.lineFragmentPadding = 0
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = true
        view.isUserInteractionEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.isHidden = true
        return view
    }()

    private(set) var surface: ghostty_surface_t?
    private var lastReportedSize: TerminalGridSize?
    /// Latest natural grid awaiting a debounced report to the Mac. The display
    /// link sends it only after the grid has held steady for
    /// `viewportReportSettleThreshold` frames. Reporting every intermediate
    /// size during the attach / keyboard / zoom settle resized the Mac PTY
    /// repeatedly, so the shell redrew its prompt on each SIGWINCH and the
    /// initial scrollback filled with the prompt duplicated at every width.
    private var pendingViewportReport: TerminalGridSize?
    private var viewportReportSettleFrames = 0
    /// Frames of "no zoom in progress" required before the natural grid is
    /// reported to the Mac. Longer than the local geometry settle so a zoom
    /// gesture (with brief pauses between steps) renegotiates the shared grid
    /// once, not on every micro-pause. ~0.25s at 120Hz / 0.5s at 60Hz.
    private static let viewportReportSettleThreshold = 30
    private var lastSnapshotFallbackHTML: String?
    /// Daemon-authoritative effective grid (min across attached devices). When
    /// set, the Ghostty surface is pinned to this cols×rows inside the
    /// container so every attached device renders at the same grid. When
    /// nil, the surface fills the container's natural capacity.
    private var effectiveGrid: (cols: Int, rows: Int)?
    /// Cached cell metrics derived from the most recent
    /// `ghostty_surface_size` measurement. Used to translate an effective
    /// cols×rows pin into a pixel box without re-round-tripping through
    /// Ghostty. Zero until the first layout has measured.
    private var cellPixelSize: CGSize = .zero
    /// 1 px separator stroke drawn around the pinned surface rect when the
    /// container is larger than the render target (i.e., this device is
    /// not the smallest). Added lazily on first letterbox.
    private var letterboxBorderLayer: CAShapeLayer?
    /// Last render rect used for the Ghostty surface inside the host view's
    /// coordinate space. Kept so the border layer can match it without a
    /// second set_size round-trip.
    private var lastRenderRect: CGRect = .zero

    #if DEBUG
    struct DebugGeometrySnapshot {
        let boundsSize: CGSize
        let renderRect: CGRect
        let screenScale: CGFloat
        let reportedSize: TerminalGridSize?
        let renderedSize: TerminalGridSize?
        let isLetterboxBorderVisible: Bool
        let letterboxBorderPathBounds: CGRect?
    }

    func debugGeometrySnapshotForTesting() -> DebugGeometrySnapshot {
        let renderedSize: TerminalGridSize? = {
            guard let surface else { return nil }
            let size = ghostty_surface_size(surface)
            return TerminalGridSize(
                columns: Int(size.columns),
                rows: Int(size.rows),
                pixelWidth: Int(size.width_px),
                pixelHeight: Int(size.height_px)
            )
        }()
        return DebugGeometrySnapshot(
            boundsSize: bounds.size,
            renderRect: lastRenderRect,
            screenScale: preferredScreenScale,
            reportedSize: lastReportedSize,
            renderedSize: renderedSize,
            isLetterboxBorderVisible: letterboxBorderLayer?.isHidden == false,
            letterboxBorderPathBounds: letterboxBorderLayer?.path?.boundingBoxOfPath
        )
    }

    func setKeyboardHeightForTesting(_ height: CGFloat) {
        keyboardHeight = max(0, height)
        syncSurfaceGeometry(shouldReassertNaturalSize: true)
    }
    #endif

    var currentGridSize: TerminalGridSize {
        lastReportedSize ?? TerminalGridSize(columns: 100, rows: 32, pixelWidth: 900, pixelHeight: 650)
    }

    private lazy var inputProxy: TerminalInputTextView = {
        let inputProxy = TerminalInputTextView()
        inputProxy.onText = { [weak self] text in
            guard let self else { return }
            self.resetCursorBlink()
            #if DEBUG
            self.lastInputTimestamp = CACurrentMediaTime()
            #endif
            // Send all text directly to the transport as raw bytes.
            // Ghostty is display-only; the remote server handles echo.
            // Replace \n with \r (terminals expect CR for Return).
            let normalized = text.replacingOccurrences(of: "\n", with: "\r")
            let data = Data(normalized.utf8)
            TerminalInputDebugLog.log("surface.onText text=\(TerminalInputDebugLog.textSummary(text)) data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onBackspace = { [weak self] in
            guard let self else { return }
            self.resetCursorBlink()
            // Send DEL (0x7F) directly to transport as raw byte.
            let data = Data([0x7F])
            TerminalInputDebugLog.log("surface.onBackspace data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onEscapeSequence = { [weak self] data in
            guard let self else { return }
            self.resetCursorBlink()
            TerminalInputDebugLog.log("surface.onEscape data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onZoom = { [weak self] direction in
            self?.performFontZoom(direction)
        }
        inputProxy.onHideKeyboard = { [weak self] in
            self?.inputProxy.resignFirstResponder()
        }
        inputProxy.accessoryLayoutInsetsProvider = { [weak self] in
            guard let self,
                  let window = self.window else {
                return .zero
            }

            let terminalFrame = self.convert(self.bounds, to: window)
            return UIEdgeInsets(
                top: 0,
                left: max(0, terminalFrame.minX),
                bottom: 0,
                right: max(0, window.bounds.maxX - terminalFrame.maxX)
            )
        }
        return inputProxy
    }()

    public init(runtime: GhosttyRuntime, delegate: GhosttySurfaceViewDelegate, fontSize: Float32 = 10) {
        self.runtime = runtime
        self.delegate = delegate
        self.fontSize = fontSize
        self.liveFontSize = fontSize
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        bridge.attach(to: self)
        backgroundColor = .black
        isOpaque = true
        #if DEBUG
        accessibilityIdentifier = "MobileTerminalSurface"
        isAccessibilityElement = true
        #endif
        addSubview(snapshotFallbackView)
        addSubview(inputProxy)
        initializeSurface()

        let tap = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func handleAppDidEnterBackground() {
        guard let surface else { return }
        stopDisplayLink()
        setFocus(false)
        ghostty_surface_set_occlusion(surface, false)  // false = not visible (occluded)
    }

    @objc private func handleAppWillEnterForeground() {
        guard let surface, window != nil else { return }
        ghostty_surface_set_occlusion(surface, true)  // true = visible
        setFocus(true)
        startDisplayLink()
    }

    private var keyboardHeight: CGFloat = 0
    var autoFocusOnWindowAttach = true

    @objc private func handleKeyboardWillShow(_ notification: Notification) {
        guard let frameEnd = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window else { return }
        let keyboardFrameInView = convert(frameEnd, from: window)
        let overlap = max(0, bounds.maxY - keyboardFrameInView.minY)
        guard overlap != keyboardHeight else { return }
        keyboardHeight = overlap
        setNeedsGeometrySync()
    }

    @objc private func handleKeyboardWillHide(_ notification: Notification) {
        guard keyboardHeight != 0 else { return }
        keyboardHeight = 0
        setNeedsGeometrySync()
    }

    private var pinchAccumulatedScale: CGFloat = 1.0

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            liveAnchormuxLog("scroll.pan state=\(gesture.state.rawValue) ty=\(Int(gesture.translation(in: self).y))")
        }
        if gesture.state == .changed {
            let translation = gesture.translation(in: self)
            // iOS natural scrolling: swipe down (positive translation) = scroll up (show history).
            // Ghostty: positive y = scroll down. So pass translation.y directly for natural feel.
            let scrollY = translation.y / 10.0
            // `ghostty_surface_mouse_scroll` takes the same renderer/IO lock as
            // `process_output`. Calling it on the MAIN thread during a render
            // storm wedged the main thread on libghostty's futex until the
            // scene-update watchdog (0x8BADF00D) killed the app — a hang report
            // showed the main thread in `Thread.Futex.Deadline.wait` inside this
            // gesture handler. Run it on the serial surface queue like every
            // other `ghostty_surface_*` op so it can never block the main thread.
            Self.outputQueue.async {
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollY), 0)
            }
            gesture.setTranslation(.zero, in: self)
            needsDraw = true
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchAccumulatedScale = 1.0
        case .changed:
            let delta = gesture.scale - pinchAccumulatedScale
            if abs(delta) >= 0.15 {
                let direction: TerminalFontZoomDirection = delta > 0 ? .increase : .decrease
                if performFontZoom(direction) {
                    pinchAccumulatedScale = gesture.scale
                }
            }
        case .ended, .cancelled:
            // Final sync to make sure the last font change is applied.
            setNeedsGeometrySync()
        default:
            break
        }
    }

    @discardableResult
    private func performFontZoom(_ direction: TerminalFontZoomDirection) -> Bool {
        // Coalesce zoom: each tap only updates `pendingFontSize`; the display
        // link applies the LATEST target once per frame via an absolute
        // `set_font_size` (see `applyPendingFontSizeIfNeeded`). A burst of taps
        // therefore becomes one libghostty push + one resize per frame instead
        // of one per tap.
        //
        // Why this matters: every libghostty surface op on iOS runs on the
        // serial `outputQueue`, and they all BLOCK — the font push is a
        // `.forever` mailbox push, and the render that drains it waits on a
        // free GPU frame. Dispatching one blocking push per tap let the queue
        // accumulate pushes faster than the per-frame render drained them, so
        // the queue wedged and zoom froze. Coalescing caps the work at one
        // push per frame, which the render keeps pace with.
        //
        // Base the next step on `pendingFontSize` when a target is already
        // queued, so taps within the same frame still accumulate correctly.
        let delta: Float32 = direction == .increase ? 1 : -1
        let base = pendingFontSize ?? liveFontSize
        let target = base + delta
        guard target >= MobileTerminalFontPreference.minimumSize,
              target <= MobileTerminalFontPreference.maximumSize else {
            liveAnchormuxLog("zoom.clamp dir=\(direction) base=\(base) target=\(target) range=[\(MobileTerminalFontPreference.minimumSize),\(MobileTerminalFontPreference.maximumSize)]")
            return false
        }
        guard surface != nil else { return false }

        pendingFontSize = target
        liveAnchormuxLog("zoom.queue dir=\(direction) \(base)->\(target) live=\(liveFontSize)")
        scheduleDisplayLinkWork()
        return true
    }

    /// Ensure a queued zoom (`pendingFontSize`) actually gets applied. While the
    /// display link runs, `handleDisplayLinkFire` picks the target up on the
    /// next frame. If the link is stopped (detached / backgrounded) nothing
    /// would pump it, so apply immediately.
    private func scheduleDisplayLinkWork() {
        needsDraw = true
        if displayLink == nil {
            applyPendingFontSizeIfNeeded()
        }
    }

    /// Apply the latest queued zoom target, called once per display-link frame.
    /// Pushes an absolute `set_font_size` off the main thread and renders the
    /// new font WITHOUT resizing the surface — geometry is resynced once after
    /// zoom settles (see `zoomSettleFrames`). Returns whether a font change was
    /// applied this frame.
    @discardableResult
    private func applyPendingFontSizeIfNeeded() -> Bool {
        guard let target = pendingFontSize, let surface else { return false }
        pendingFontSize = nil
        guard target != liveFontSize else { return false }
        liveFontSize = target
        liveAnchormuxLog("zoom.apply \(target) eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")")
        // Absolute set: the prior `±1` binding action drove libghostty's own
        // font counter independently of our clamp, so a fast burst could push
        // it past `maximumSize` toward the 255pt ceiling and collapse the grid.
        // An absolute `set_font_size:<target>` keeps libghostty in lockstep
        // with `liveFontSize`, which we keep inside [minimumSize, maximumSize].
        let action = "set_font_size:\(target)"
        Self.outputQueue.async {
            action.withCString { pointer in
                _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
        }
        // Render the new font (the grid reflows inside the current surface) but
        // do NOT resize the surface this frame. Resizing the render target on
        // every zoom step reallocates the IOSurface and stalls `render_now`'s
        // GPU frame wait (the wedge). Defer one geometry resync until zoom goes
        // quiet via the settle counter, re-armed on every apply.
        needsDraw = true
        zoomSettleFrames = Self.zoomSettleFrameThreshold
        return true
    }

    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    #if DEBUG
    /// Repro hook for the `CMUX_ZOOM_STRESS` harness: drive one font-zoom
    /// step exactly as pinch / the accessory buttons do, so the harness can
    /// hammer the zoom path and reproduce the fast-zoom crash locally.
    func debugStressZoomStep(_ direction: TerminalFontZoomDirection) {
        performFontZoom(direction)
    }
    #endif

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        disposeSurface()
    }

    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        snapshotFallbackView.frame = bounds
        inputProxy.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        inputProxy.updateAccessoryLayoutInsets()
        liveAnchormuxLog("surface.layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) window=\(window != nil)")
        setNeedsGeometrySync()
        syncSurfaceVisibility()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        liveAnchormuxLog("surface.didMoveToWindow window=\(window != nil)")
        syncSurfaceVisibility()
        if window != nil {
            setNeedsGeometrySync()
            setFocus(true)
            if autoFocusOnWindowAttach {
                focusInput()
            }
            startDisplayLink()
        } else {
            stopDisplayLink()
            setFocus(false)
        }
    }

    private var lastProcessOutputLogTime: CFTimeInterval = 0

    public func processOutput(_ data: Data) {
        guard let surface else { return }
        #if DEBUG
        if lastInputTimestamp > 0 {
            let elapsed = (CACurrentMediaTime() - lastInputTimestamp) * 1000.0
            lastInputTimestamp = 0
            latencySamples.append(elapsed)
            if latencySamples.count % 10 == 0 {
                let sorted = latencySamples.sorted()
                let avg = latencySamples.reduce(0, +) / Double(latencySamples.count)
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count) * 0.95)]
                log.debug("Keypress latency (\(self.latencySamples.count, privacy: .public) samples): avg=\(avg, privacy: .public)ms p50=\(p50, privacy: .public)ms p95=\(p95, privacy: .public)ms min=\(sorted.first!, privacy: .public)ms max=\(sorted.last!, privacy: .public)ms")
            }
        }
        #endif
        let forwarded = Self.forwardDaemonOutputBytes(data)

        // `ghostty_surface_process_output` BLOCKS on libghostty's internal
        // renderer/IO synchronization (a futex). Device crash logs show it
        // hanging the main thread (`Thread.Futex.Deadline.wait`) until the
        // scene-update watchdog (0x8BADF00D) kills the app. It must run off
        // the main thread. Feed it on a serial background queue (order
        // preserved) and hop back to main only for the Swift-side UI state.
        Self.outputQueue.async { [weak self] in
            forwarded.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(surface, pointer, UInt(buffer.count))
            }
            #if DEBUG
            // `ghostty_surface_read_text` takes the same internal surface lock as
            // `process_output`. Reading it on the MAIN thread per-output (to feed
            // the XCUITest accessibility label) contended that lock against the
            // off-main renderer/IO during a fast render storm and wedged the main
            // thread on libghostty's futex until the scene-update watchdog
            // (0x8BADF00D) froze the app. Read it HERE on the serial output queue
            // instead — already serialized with `process_output`, so the two are
            // never concurrent — throttled, and hand only the finished string to
            // main. Off-main reads can never trip the main-thread watchdog.
            var accessibilityText: String?
            let a11yNow = CACurrentMediaTime()
            if a11yNow - Self.lastAccessibilityTextTime > 0.5 {
                Self.lastAccessibilityTextTime = a11yNow
                accessibilityText = Self.accessibilitySurfaceText(surface)
            }
            #endif
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDraw = true
                if !self.surfaceHasReceivedOutput {
                    self.surfaceHasReceivedOutput = true
                    self.snapshotFallbackView.isHidden = true
                    self.scrollInitialOutputToBottomIfNeeded()
                }
                let now = CACurrentMediaTime()
                if now - self.lastProcessOutputLogTime > 1.0 {
                    self.lastProcessOutputLogTime = now
                    if self.window != nil {
                        self.logLayerTree(reason: "processOutput")
                    }
                }
                #if DEBUG
                if let accessibilityText, !accessibilityText.isEmpty {
                    self.accessibilityLabel = accessibilityText
                }
                self.onOutputProcessedForTesting?()
                #endif
            }
        }
    }

    private func scrollInitialOutputToBottomIfNeeded() {
        guard shouldScrollInitialOutputToBottom else { return }
        shouldScrollInitialOutputToBottom = false
        _ = performBindingAction("scroll_to_bottom")
    }

    static func forwardDaemonOutputBytes(_ data: Data) -> Data {
        // The daemon owns terminal byte semantics. iOS must feed Ghostty the
        // exact VT stream it received so desktop and mobile render the same
        // session history and prompt state.
        data
    }

    @objc
    func focusInput() {
        onFocusInputRequestedForTesting?()
        setNeedsGeometrySync()
        inputProxy.updateAccessoryLayoutInsets()
        inputProxy.becomeFirstResponder()
    }

    func updateRemotePlatform(_ platform: RemotePlatform) {
        inputProxy.updateModifierLabels(isMacRemote: platform.goOS == "darwin")
    }

    func simulateTextInputForTesting(_ text: String) {
        setFocus(true)
        sendText(text)
        runtime?.tick()
    }

    func simulatePasteInputForTesting(_ text: String) {
        setFocus(true)
        sendPaste(text)
        runtime?.tick()
    }

    func simulateInputProxyTextChangeForTesting(_ text: String, isComposing: Bool) {
        setFocus(true)
        inputProxy.simulateTextChangeForTesting(text, isComposing: isComposing)
        runtime?.tick()
    }

    func renderedTextForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        guard let surface else { return nil }

        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }

        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    #if DEBUG
    func accessibilityRenderedTextForTesting() -> String? {
        let candidates = [
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SURFACE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_ACTIVE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }

        return candidates.max { lhs, rhs in
            lhs.utf8.count < rhs.utf8.count
        }
    }

    /// Throttle stamp for the off-main accessibility-label read in
    /// `processOutput`. Accessed only on the serial `outputQueue`, so the
    /// unchecked mutation is safe.
    nonisolated(unsafe) fileprivate static var lastAccessibilityTextTime: CFTimeInterval = 0

    /// Off-main equivalent of ``accessibilityRenderedTextForTesting()`` that
    /// reads via the raw surface handle so it can run on the serial output queue
    /// (alongside `process_output`) instead of the main thread. See the call
    /// site in `processOutput` for why a main-thread read deadlocks the watchdog.
    nonisolated static func accessibilitySurfaceText(_ surface: ghostty_surface_t) -> String? {
        let candidates = [
            surfaceText(surface, pointTag: GHOSTTY_POINT_SURFACE),
            surfaceText(surface, pointTag: GHOSTTY_POINT_SCREEN),
            surfaceText(surface, pointTag: GHOSTTY_POINT_ACTIVE),
            surfaceText(surface, pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }
        return candidates.max { $0.utf8.count < $1.utf8.count }
    }

    /// Read the surface text for `pointTag` from the raw handle. Pure libghostty
    /// C calls, safe to run off the main actor on the serial output queue.
    nonisolated static func surfaceText(_ surface: ghostty_surface_t, pointTag: ghostty_point_tag_e) -> String? {
        let topLeft = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }
    #endif

    func renderedHTMLForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        _ = pointTag
        // ghostty_surface_read_text_html not available in this build
        return nil
    }

    func processExitedForTesting() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface)
    }

    func disposeSurface() {
        stopDisplayLink()
        guard let surface else { return }
        GhosttySurfaceView.unregister(surface: surface)
        self.surface = nil
        bridge.detach()
        GhosttySurfaceDisposer.dispose(surface: surface, bridge: bridge)
    }

    private var preferredScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }

        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    private func sendText(_ text: String) {
        guard let surface else { return }
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        let count = normalized.utf8CString.count
        guard count > 1 else { return }
        normalized.withCString { pointer in
            ghostty_surface_text_input(surface, pointer, UInt(count - 1))
        }
    }

    private func sendPaste(_ text: String) {
        guard let surface else { return }
        let count = text.utf8CString.count
        guard count > 0 else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(count - 1))
        }
    }

    private func initializeSurface() {
        guard let app = runtime?.app else { return }
        surface = makeSurface(app: app)
        if let surface {
            GhosttySurfaceView.register(surface: surface, for: self)
            if let config = runtime?.config {
                applyBackgroundColorFromConfig(config)
            }
            // Hide the snapshot fallback immediately. The Metal renderer
            // handles all rendering once the surface exists.
            snapshotFallbackView.isHidden = true
            surfaceHasReceivedOutput = true
        }
        setNeedsGeometrySync()
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.handleDisplayLink))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        cursorBlinkState.start(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        cursorOverlayLayer?.isHidden = true
    }

    /// Reset cursor to visible and restart blink cycle (call on user input).
    private func resetCursorBlink() {
        guard surface != nil else { return }
        cursorBlinkState.reset(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    @objc func handleDisplayLinkFire() {
        guard let surface else { return }
        // Apply at most one coalesced zoom per frame. This only changes the
        // font; the geometry resync is deferred until zoom settles.
        let appliedZoom = applyPendingFontSizeIfNeeded()
        // Post-zoom geometry resync: once no new zoom target has landed for a
        // few quiet frames, do ONE resize to re-pin the letterbox at the
        // settled font. This is the single geometry change per zoom gesture
        // instead of one per step (which thrashed the IOSurface and wedged the
        // render queue).
        if !appliedZoom, var frames = zoomSettleFrames {
            frames -= 1
            if frames <= 0 {
                zoomSettleFrames = nil
                setNeedsGeometrySync()
            } else {
                zoomSettleFrames = frames
            }
        }
        // Apply geometry at most once per frame. Every trigger (resize, zoom,
        // keyboard, effective-grid pin) only marks `needsGeometrySync`, so a
        // fast pinch can no longer drive a synchronous per-event storm of
        // set_size calls (the source of the jumbled grid + renderer overload).
        if needsGeometrySync {
            needsGeometrySync = false
            let reassert = pendingGeometryReassert
            pendingGeometryReassert = false
            syncSurfaceGeometry(shouldReassertNaturalSize: reassert)
        }
        let now = CACurrentMediaTime()
        let blinkChanged = cursorBlinkState.advance(now: now)
        // Draw on content/cursor changes, and for a short bounded burst after
        // any geometry change. iOS has no renderer-side vsync, so a frame is
        // only produced when we ask. The renderer draws at the layer size read
        // at draw time and presents a frame behind, so a single post-resize
        // draw can land while the layer is still mid-animation, leaving a
        // stale, wrong-size surface on screen (the blank / crushed-strip
        // garble). Requesting a few extra frames after the geometry settles
        // guarantees a draw at the final size. It is bounded (not a perpetual
        // loop) so it never floods the main queue with `setSurface` present
        // blocks, which made the app unresponsive.
        let geometrySettling = pendingRenderFrames > 0
        if geometrySettling { pendingRenderFrames -= 1 }
        if needsDraw || blinkChanged || geometrySettling {
            needsDraw = false
            requestRender()
            updateCursorOverlay()
        }

        // Report the settled natural grid to the Mac once it has stopped
        // changing. `applyGeometryResult` resets the counter on every grid
        // change, so this only fires after the attach/keyboard/zoom settle —
        // one PTY resize instead of one per intermediate size.
        //
        // While a zoom is still in progress (`zoomSettleFrames` armed = a zoom
        // landed within the last few frames) HOLD the report entirely. Each
        // zoom step changes the natural grid; reporting mid-zoom makes the Mac
        // resize the PTY over and over, so a full-screen TUI (a coding agent,
        // vim, etc.) redraws at constantly-changing sizes and garbles into the
        // "bad intermediate state". Zoom is a LOCAL font change; the shared
        // grid should renegotiate exactly once, after the user settles.
        if let pending = pendingViewportReport {
            if zoomSettleFrames != nil {
                viewportReportSettleFrames = 0
            } else {
                viewportReportSettleFrames += 1
                if viewportReportSettleFrames >= Self.viewportReportSettleThreshold {
                    pendingViewportReport = nil
                    viewportReportSettleFrames = 0
                    liveAnchormuxLog("zoom.report grid=\(pending.columns)x\(pending.rows)")
                    delegate?.ghosttySurfaceView(self, didResize: pending)
                }
            }
        }
    }

    /// Drive a full render cycle via `ghostty_surface_render_now`, dispatched
    /// to the off-main surface queue.
    ///
    /// On iOS libghostty's renderer-thread event loop does not pump frames
    /// (it's a platform-display-driven embedder), so `ghostty_surface_refresh`
    /// — which only wakes that loop — never produces a frame: `updateFrame`
    /// doesn't run, the cell grid stays 0x0, and the surface renders blank
    /// (uninitialized buffer shows as garbled). `render_now` instead runs
    /// `applyPendingResizeIfNeeded` + drainMailbox + `updateFrame` + drawFrame
    /// directly on the calling thread, so the terminal grid is sized and the
    /// cells are rebuilt from real content. We run it on `outputQueue` so the
    /// GPU encode/swap-chain wait stays OFF the main thread (calling it on main
    /// is what tripped the scene-update watchdog under fast zoom). The present
    /// still hops to main inside libghostty (`setSurface`). The display link
    /// gates this on `needsDraw`/`pendingRenderFrames`, so it is not a
    /// per-frame loop that would flood the main queue with present blocks.
    private func requestRender() {
        guard let surface else { return }
        // Coalesce: never let more than one render_now sit on the serial queue.
        // (Called on main from the display link.)
        if renderInFlight {
            needsAnotherRender = true
            return
        }
        renderInFlight = true
        let enqueuedAt = CACurrentMediaTime()
        Self.outputQueue.async { [weak self] in
            // Queue LAG = how long this render waited behind other ops. If this
            // climbs into hundreds of ms the queue is backlogged (the freeze).
            let lagMs = (CACurrentMediaTime() - enqueuedAt) * 1000
            if lagMs > 150 { liveAnchormuxLog("oq.render.LAG \(Int(lagMs))ms") }
            ghostty_surface_render_now(surface)
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderInFlight = false
                if self.needsAnotherRender {
                    self.needsAnotherRender = false
                    self.requestRender()
                }
            }
        }
    }

    /// Request a geometry recompute on the next display-link frame. Triggers
    /// must call this instead of `syncSurfaceGeometry` directly so rapid
    /// events coalesce into one apply per frame.
    private func setNeedsGeometrySync(reassertNaturalSize: Bool = true) {
        needsGeometrySync = true
        if reassertNaturalSize { pendingGeometryReassert = true }
        needsDraw = true
        // A geometry sync (for any reason) satisfies a pending post-zoom resync.
        zoomSettleFrames = nil
        if displayLink == nil, window != nil {
            // No frame pump while detached/backgrounded; apply directly so the
            // surface still gets sized before the next render path resumes.
            needsGeometrySync = false
            let reassert = pendingGeometryReassert
            pendingGeometryReassert = false
            syncSurfaceGeometry(shouldReassertNaturalSize: reassert)
        }
    }

    private func updateCursorOverlay() {
        guard let surface,
              window != nil,
              !isHidden,
              alpha > 0.01,
              !lastRenderRect.isEmpty,
              cellPixelSize.width > 0,
              cellPixelSize.height > 0 else {
            cursorOverlayLayer?.isHidden = true
            return
        }
        let overlay = ensureCursorOverlayLayer()
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let scale = max(preferredScreenScale, 1)
        overlay.contentsScale = scale
        let cellWidth = max(cellPixelSize.width / scale, 1)
        let cellHeight = max(CGFloat(height), cellPixelSize.height / scale, 1)
        let cursorWidth = max(1.0 / scale, min(CGFloat(1.5), cellWidth))
        let cursorX = lastRenderRect.minX + CGFloat(x) - (cellWidth / 2)
        let cursorY = lastRenderRect.minY + CGFloat(y) - cellHeight
        overlay.frame = CGRect(
            x: floor(cursorX),
            y: floor(cursorY),
            width: cursorWidth,
            height: ceil(cellHeight)
        )
        overlay.backgroundColor = cursorBlinkState.isVisible
            ? (configCursorColor ?? UIColor(red: 0xc0/255.0, green: 0xc1/255.0, blue: 0xb5/255.0, alpha: 1.0)).cgColor
            : (configBackgroundColor ?? backgroundColor ?? .black).cgColor
        overlay.isHidden = false
    }

    private func ensureCursorOverlayLayer() -> CALayer {
        if let cursorOverlayLayer {
            return cursorOverlayLayer
        }
        let layer = CALayer()
        layer.name = "cmux.cursorOverlay"
        layer.zPosition = 1001
        layer.actions = [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
        ]
        self.layer.addSublayer(layer)
        cursorOverlayLayer = layer
        return layer
    }

    private(set) var configBackgroundColor: UIColor?
    private(set) var configCursorColor: UIColor?

    private func applyBackgroundColorFromConfig(_ config: ghostty_config_t) {
        var bgColor = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &bgColor, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            let bg = UIColor(red: CGFloat(bgColor.r) / 255.0, green: CGFloat(bgColor.g) / 255.0, blue: CGFloat(bgColor.b) / 255.0, alpha: 1.0)
            backgroundColor = bg
            snapshotFallbackView.backgroundColor = bg
            configBackgroundColor = bg
            #if DEBUG
            log.debug("applyBg: config r=\(bgColor.r, privacy: .public) g=\(bgColor.g, privacy: .public) b=\(bgColor.b, privacy: .public) -> UIColor(\(bg.debugDescription, privacy: .public)), hardcoded Monokai=#272822 r=39 g=40 b=34")
            #endif
        } else {
            #if DEBUG
            log.debug("applyBg: ghostty_config_get returned false, no bg color from config")
            #endif
        }
        var fgColor = ghostty_config_color_s()
        let fgKey = "foreground"
        if ghostty_config_get(config, &fgColor, fgKey, UInt(fgKey.lengthOfBytes(using: .utf8))) {
            snapshotFallbackView.textColor = UIColor(red: CGFloat(fgColor.r) / 255.0, green: CGFloat(fgColor.g) / 255.0, blue: CGFloat(fgColor.b) / 255.0, alpha: 1.0)
        }
        var cursorColor = ghostty_config_color_s()
        let cursorKey = "cursor-color"
        if ghostty_config_get(config, &cursorColor, cursorKey, UInt(cursorKey.lengthOfBytes(using: .utf8))) {
            configCursorColor = UIColor(
                red: CGFloat(cursorColor.r) / 255.0,
                green: CGFloat(cursorColor.g) / 255.0,
                blue: CGFloat(cursorColor.b) / 255.0,
                alpha: 1.0
            )
        }
    }

    private func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    private func syncSurfaceVisibility() {
        guard let surface else { return }
        let visible = window != nil &&
            !isHidden &&
            alpha > 0.01 &&
            bounds.width > 0 &&
            bounds.height > 0
        liveAnchormuxLog("surface.occlusion visible=\(visible) window=\(window != nil) hidden=\(isHidden) alpha=\(alpha)")
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            updateCursorOverlay()
        } else {
            cursorOverlayLayer?.isHidden = true
        }
    }

    public func applyViewSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if effectiveGrid?.cols == cols && effectiveGrid?.rows == rows { return }
        liveAnchormuxLog("zoom.applyViewSize eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")->\(cols)x\(rows)")
        effectiveGrid = (cols, rows)
        // Mark dirty instead of recomputing synchronously. This breaks the
        // feedback loop (didResize → updateTerminalViewport RPC → applyViewSize
        // → syncSurfaceGeometry → didResize …) that, under fast zoom, drove a
        // storm of set_size calls + viewport RPCs. Geometry now settles once
        // per frame, and reassert=false avoids re-reporting the unchanged
        // natural grid back through the round trip.
        setNeedsGeometrySync(reassertNaturalSize: false)
    }

    /// Pure libghostty resize refinement; `nonisolated` so it runs on the
    /// off-main surface queue (it touches only the passed surface pointer).
    nonisolated private static func fitSurfaceToGrid(
        _ surface: ghostty_surface_t,
        cols: Int,
        rows: Int,
        cellPixelSize: CGSize
    ) -> (requestedW: UInt32, requestedH: UInt32, actual: ghostty_surface_size_s) {
        var requestedW = UInt32(max(1, Int((CGFloat(cols) * cellPixelSize.width).rounded(.down))))
        var requestedH = UInt32(max(1, Int((CGFloat(rows) * cellPixelSize.height).rounded(.down))))

        ghostty_surface_set_size(surface, requestedW, requestedH)
        var actual = ghostty_surface_size(surface)

        // Ghostty's grid calculation subtracts padding and floors partial cells,
        // so the reverse mapping has to be confirmed against Ghostty itself.
        // This keeps the iOS mirror on the exact daemon grid instead of
        // occasionally rendering one column short.
        var steps = 0
        // Bounded refinement: a few single-pixel nudges are enough to land on
        // the exact grid. A high cap let a fast-zoom storm run this loop tens
        // of thousands of times across frames and burn the main thread.
        while steps < 8,
              Int(actual.columns) < cols || Int(actual.rows) < rows {
            if Int(actual.columns) < cols {
                requestedW += 1
            }
            if Int(actual.rows) < rows {
                requestedH += 1
            }
            ghostty_surface_set_size(surface, requestedW, requestedH)
            actual = ghostty_surface_size(surface)
            steps += 1
        }

        return (requestedW, requestedH, actual)
    }

    /// Result of an off-main geometry pass, handed back to the main actor.
    private struct GeometryResult: Sendable {
        let cellPixelSize: CGSize
        let naturalSize: TerminalGridSize
        /// Pinned render size in points when letterboxed to an effective
        /// grid; nil means fill the container.
        let pinnedSize: CGSize?
    }

    private func syncSurfaceGeometry(shouldReassertNaturalSize: Bool = true) {
        guard let surface else { return }

        // Capture all main-actor inputs as values, then do every libghostty
        // WRITE (set_content_scale / set_size / fit) and its readback on the
        // serial surface queue. These calls push to libghostty's renderer
        // mailbox with a blocking `.forever` push; on the main thread they
        // hang it until the scene-update watchdog (0x8BADF00D) kills the app.
        // The main thread only applies the UIKit result. This is the single
        // off-main surface owner: main never calls a blocking libghostty API.
        let scale = preferredScreenScale
        let bottomInset = min(max(0, keyboardHeight), max(0, bounds.height - 1))
        let containerW = max(1, bounds.width)
        let containerH = max(1, bounds.height - bottomInset)
        let containerPxW = UInt32(max(1, Int((containerW * scale).rounded(.down))))
        let containerPxH = UInt32(max(1, Int((containerH * scale).rounded(.down))))
        let eff = effectiveGrid
        let pushContentScale = abs(lastAppliedContentScale - scale) > 0.001
        if pushContentScale { lastAppliedContentScale = scale }

        Self.outputQueue.async { [weak self] in
            if pushContentScale {
                ghostty_surface_set_content_scale(surface, scale, scale)
            }
            ghostty_surface_set_size(surface, containerPxW, containerPxH)
            let measured = ghostty_surface_size(surface)

            var cell = CGSize.zero
            if measured.columns > 0, measured.rows > 0, measured.width_px > 0, measured.height_px > 0 {
                cell = CGSize(
                    width: CGFloat(measured.width_px) / CGFloat(measured.columns),
                    height: CGFloat(measured.height_px) / CGFloat(measured.rows)
                )
            }

            var pinnedSize: CGSize?
            if let eff, eff.cols > 0, eff.rows > 0, cell.width > 0, cell.height > 0 {
                let fillsNaturalGrid = eff.cols >= Int(measured.columns) && eff.rows >= Int(measured.rows)
                let withinOneCell = (Int(measured.columns) - eff.cols) <= 1 && (Int(measured.rows) - eff.rows) <= 1
                let pinnedW = CGFloat(eff.cols) * cell.width / scale
                let pinnedH = CGFloat(eff.rows) * cell.height / scale
                if !fillsNaturalGrid, !withinOneCell, pinnedW + 0.5 < containerW || pinnedH + 0.5 < containerH {
                    let fitted = Self.fitSurfaceToGrid(surface, cols: eff.cols, rows: eff.rows, cellPixelSize: cell)
                    let aw = fitted.actual.width_px > 0 ? fitted.actual.width_px : fitted.requestedW
                    let ah = fitted.actual.height_px > 0 ? fitted.actual.height_px : fitted.requestedH
                    pinnedSize = CGSize(
                        width: min(CGFloat(aw) / scale, containerW),
                        height: min(CGFloat(ah) / scale, containerH)
                    )
                }
            }

            let natural = TerminalGridSize(
                columns: Int(measured.columns),
                rows: Int(measured.rows),
                pixelWidth: Int(measured.width_px),
                pixelHeight: Int(measured.height_px)
            )
            let result = GeometryResult(cellPixelSize: cell, naturalSize: natural, pinnedSize: pinnedSize)
            DispatchQueue.main.async {
                self?.applyGeometryResult(
                    result,
                    scale: scale,
                    containerW: containerW,
                    containerH: containerH,
                    shouldReassertNaturalSize: shouldReassertNaturalSize
                )
            }
        }
    }

    /// Apply an off-main geometry pass on the main actor: only UIKit layer /
    /// cursor / border work plus the resize report. No blocking libghostty
    /// calls happen here.
    private func applyGeometryResult(
        _ result: GeometryResult,
        scale: CGFloat,
        containerW: CGFloat,
        containerH: CGFloat,
        shouldReassertNaturalSize: Bool
    ) {
        if result.cellPixelSize.width > 0, result.cellPixelSize.height > 0 {
            cellPixelSize = result.cellPixelSize
        }
        // Size the render layer to the EXACT pixel size libghostty rendered
        // (grid-aligned: cols×cellW × rows×cellH), not the raw container. The
        // present path discards any surface whose size != layer.bounds×scale,
        // and ghostty floors the grid to whole cells, so a container-sized
        // layer is up to ~one cell larger than the surface and EVERY frame is
        // discarded (blank terminal). Using the measured surface size makes
        // them match so frames present. Pinned (letterboxed) sizes are already
        // derived from the fitted surface px. Left-align + top-anchor either
        // way; any leftover container space is the letterbox margin.
        let naturalRenderSize = CGSize(
            width: max(1, CGFloat(result.naturalSize.pixelWidth) / scale),
            height: max(1, CGFloat(result.naturalSize.pixelHeight) / scale)
        )
        let renderRect = result.pinnedSize.map { CGRect(origin: .zero, size: $0) }
            ?? CGRect(origin: .zero, size: naturalRenderSize)
        lastRenderRect = renderRect
        liveAnchormuxLog(
            "geom container=\(Int(containerW))x\(Int(containerH)) scale=\(scale) "
            + "cellPx=\(Int(result.cellPixelSize.width))x\(Int(result.cellPixelSize.height)) "
            + "natural=\(result.naturalSize.columns)x\(result.naturalSize.rows) "
            + "eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil") "
            + "pinned=\(result.pinnedSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil") "
            + "renderRect=\(Int(renderRect.width))x\(Int(renderRect.height))"
        )
        syncRendererLayerFrame(scale: scale, renderRect: renderRect)
        updateLetterboxBorder(
            renderRect: renderRect,
            isLetterboxed: renderRect.width + 0.5 < containerW || renderRect.height + 0.5 < containerH
        )
        updateCursorOverlay()
        needsDraw = true
        // Keep drawing for several frames so a frame lands at the final settled
        // layer size after CoreAnimation commits the bounds change. libghostty
        // discards a present whose surface size != the live layer (avoids the
        // garbled mis-scaled frame), so we must re-draw at the stable size until
        // one passes; otherwise the terminal stays blank. Bounded to avoid a
        // perpetual main-queue present flood. The renderer presents a frame
        // behind (see display link).
        pendingRenderFrames = 6
        syncSnapshotFallback()

        let naturalSize = result.naturalSize
        let effectiveMatchesNatural = effectiveGrid.map { grid in
            grid.cols == naturalSize.columns && grid.rows == naturalSize.rows
        } ?? true
        let shouldReportNaturalSize = naturalSize != lastReportedSize ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural)
        guard shouldReportNaturalSize, naturalSize.columns > 0, naturalSize.rows > 0 else { return }
        lastReportedSize = naturalSize
        // Debounce the actual report (a PTY resize on the Mac) until the grid
        // settles; the display link fires it once it stops changing.
        pendingViewportReport = naturalSize
        viewportReportSettleFrames = 0
    }

    private func syncRendererLayerFrame(scale: CGFloat, renderRect: CGRect) {
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] where isGhosttyRendererLayer(sublayer) {
            if sublayer.frame != renderRect {
                sublayer.frame = renderRect
            }
            if sublayer.bounds.size != renderRect.size {
                sublayer.bounds = CGRect(origin: .zero, size: renderRect.size)
            }
            sublayer.contentsScale = scale
        }
    }

    /// Add / update a 1-pixel separator border around the pinned surface
    /// rect when the container is larger (this device is not the smallest
    /// attached to the shared PTY). Smallest-device layouts have
    /// `isLetterboxed == false` and the border layer is hidden. Uses a
    /// CAShapeLayer so the stroke doesn't intercept touches / key events.
    private func updateLetterboxBorder(renderRect: CGRect, isLetterboxed: Bool) {
        guard isLetterboxed else {
            letterboxBorderLayer?.isHidden = true
            return
        }
        let border: CAShapeLayer = {
            if let existing = letterboxBorderLayer { return existing }
            let b = CAShapeLayer()
            b.name = "cmux.letterboxBorder"
            b.fillColor = UIColor.clear.cgColor
            b.lineWidth = 1.0
            b.zPosition = 1000 // above the Ghostty renderer layer
            b.isHidden = false
            b.actions = [
                "bounds": NSNull(),
                "frame": NSNull(),
                "hidden": NSNull(),
                "opacity": NSNull(),
                "path": NSNull(),
                "position": NSNull(),
                "strokeColor": NSNull(),
            ]
            // Decorative only; let pointer / key events pass through.
            b.isGeometryFlipped = false
            layer.addSublayer(b)
            letterboxBorderLayer = b
            return b
        }()
        border.isHidden = false
        border.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        border.contentsScale = layer.contentsScale
        if border.frame != layer.bounds {
            border.frame = layer.bounds
        }

        let scale = max(border.contentsScale, 1)
        let lineWidth = border.lineWidth
        let alignedRect = CGRect(
            x: floor(renderRect.minX * scale) / scale,
            y: floor(renderRect.minY * scale) / scale,
            width: ceil(renderRect.width * scale) / scale,
            height: ceil(renderRect.height * scale) / scale
        )
        let pathInset = max(lineWidth / 2, 0.5 / scale)
        let outline = alignedRect.insetBy(dx: pathInset, dy: pathInset)
        let path = UIBezierPath(rect: outline).cgPath
        if border.path != path {
            border.path = path
        }
    }

    private func isGhosttyRendererLayer(_ layer: CALayer) -> Bool {
        String(describing: type(of: layer)) == "IOSurfaceLayer"
    }

    private func logLayerTree(reason: String) {
        let hostLayer = layer
        let hostSummary = "\(type(of: hostLayer)) bounds=\(hostLayer.bounds.integral.debugDescription) frame=\(hostLayer.frame.integral.debugDescription) contentsScale=\(hostLayer.contentsScale)"
        let childSummaries = (hostLayer.sublayers ?? []).prefix(4).enumerated().map { index, sublayer in
            "\(index):\(type(of: sublayer)) bounds=\(sublayer.bounds.integral.debugDescription) frame=\(sublayer.frame.integral.debugDescription) hidden=\(sublayer.isHidden) contents=\(sublayer.contents != nil) scale=\(sublayer.contentsScale)"
        }.joined(separator: " | ")
        liveAnchormuxLog("surface.layers reason=\(reason) host=\(hostSummary) children=[\(childSummaries)] fallbackHidden=\(snapshotFallbackView.isHidden) fallbackChars=\(snapshotFallbackView.text.count)")
    }

    private func makeSurface(app: ghostty_app_t) -> ghostty_surface_t? {
        var surfaceConfig = ghostty_surface_config_new()
        let bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.userdata = bridgePointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.scale_factor = preferredScreenScale
        surfaceConfig.font_size = fontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = { userdata, buf, len in
            guard let userdata, let buf, len > 0 else { return }
            let data = Data(bytes: buf, count: Int(len))
            let bridge = Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                bridge.surfaceView?.handleOutboundBytes(data)
            }
        }
        surfaceConfig.io_write_userdata = bridgePointer
        return ghostty_surface_new(app, &surfaceConfig)
    }

    func handleOutboundBytes(_ bytes: Data) {
        delegate?.ghosttySurfaceView(self, didProduceInput: bytes)
    }

    func drawForWakeup() {
        guard surface != nil, window != nil else { return }
        // Don't call `ghostty_surface_refresh` here: that wakes the renderer
        // thread to present asynchronously (`setSurface` → `dispatch_async` to
        // main → size-guard discard), which both blanks frames and competes
        // with the display-link's main-thread present. Just flag dirty; the
        // next display-link tick runs `render_now` on main (which itself does
        // drainMailbox + updateFrame), keeping a single present owner on main.
        needsDraw = true
    }

    func visibleSnapshotTextForTesting() -> String {
        snapshotFallbackView.attributedText?.string ?? snapshotFallbackView.text
    }

    func visibleSnapshotAttributedTextForTesting() -> NSAttributedString? {
        snapshotFallbackView.attributedText
    }

    func isUsingSnapshotFallbackForTesting() -> Bool {
        !snapshotFallbackView.isHidden
    }

    private func syncSnapshotFallback() {
        // Once the Metal renderer is active (surface has received output),
        // keep the fallback hidden so the IOSurfaceLayer is visible.
        if surfaceHasReceivedOutput {
            snapshotFallbackView.isHidden = true
            return
        }

        let rendererHasContents = !prefersSnapshotFallbackRendering &&
            (layer.sublayers ?? []).contains(where: isGhosttyRendererLayerVisible)
        if rendererHasContents {
            snapshotFallbackView.isHidden = true
            return
        }

        let snapshot = renderedTextForTesting() ?? ""
        guard !snapshot.isEmpty else {
            lastSnapshotFallbackHTML = nil
            snapshotFallbackView.attributedText = nil
            snapshotFallbackView.text = ""
            snapshotFallbackView.isHidden = true
            return
        }

        let html = renderedHTMLForTesting()
        if let html,
           html != lastSnapshotFallbackHTML,
           let attributedSnapshot = makeSnapshotAttributedText(from: html) {
            lastSnapshotFallbackHTML = html
            snapshotFallbackView.attributedText = attributedSnapshot
            applySnapshotFallbackTheme(from: attributedSnapshot)
        } else if snapshotFallbackView.attributedText?.string != snapshot {
            lastSnapshotFallbackHTML = nil
            snapshotFallbackView.attributedText = nil
            snapshotFallbackView.text = snapshot
        }

        if snapshotFallbackView.text != snapshot && snapshotFallbackView.attributedText == nil {
            snapshotFallbackView.text = snapshot
        }

        let visibleTextLength = snapshotFallbackView.attributedText?.string.utf16.count ?? snapshotFallbackView.text.utf16.count
        if visibleTextLength > 0 {
            snapshotFallbackView.scrollRangeToVisible(NSRange(location: max(0, visibleTextLength - 1), length: 1))
        }
        snapshotFallbackView.isHidden = false
        flushSnapshotFallbackPresentation()
    }

    private func flushSnapshotFallbackPresentation() {
        snapshotFallbackView.textContainer.size = snapshotFallbackView.bounds.size
        snapshotFallbackView.layoutManager.ensureLayout(for: snapshotFallbackView.textContainer)
        snapshotFallbackView.layoutManager.invalidateDisplay(
            forCharacterRange: NSRange(location: 0, length: snapshotFallbackView.textStorage.length)
        )
        snapshotFallbackView.setNeedsDisplay()
    }

    private func makeSnapshotAttributedText(from html: String) -> NSAttributedString? {
        let wrappedHTML = """
        <style>
        body {
            margin: 0;
            padding: 0;
            font-family: Menlo, Monaco, monospace;
            font-size: 13px;
            line-height: 1.25;
        }
        div, pre {
            white-space: pre-wrap;
        }
        </style>
        \(html)
        """
        guard let wrappedData = wrappedHTML.data(using: .utf8) else { return nil }
        return try? NSMutableAttributedString(
            data: wrappedData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    private func applySnapshotFallbackTheme(from attributedText: NSAttributedString) {
        guard attributedText.length > 0 else {
            snapshotFallbackView.backgroundColor = .black
            return
        }

        let probeIndex = firstVisibleThemeAttributeIndex(in: attributedText)
        if let background = attributedText.attribute(.backgroundColor, at: probeIndex, effectiveRange: nil) as? UIColor {
            snapshotFallbackView.backgroundColor = background
        } else {
            snapshotFallbackView.backgroundColor = .black
        }
    }

    private func firstVisibleThemeAttributeIndex(in attributedText: NSAttributedString) -> Int {
        let fullString = attributedText.string
        for (index, scalar) in fullString.unicodeScalars.enumerated() {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return index
            }
        }
        return 0
    }

    private func isGhosttyRendererLayerVisible(_ layer: CALayer) -> Bool {
        isGhosttyRendererLayer(layer) && layer.contents != nil
    }

    nonisolated private static func handleWrite(
        userdata: UnsafeMutableRawPointer?,
        data: UnsafePointer<CChar>?,
        len: UInt
    ) {
        guard let userdata, let data, len > 0 else { return }
        let bytes = Data(bytes: data, count: Int(len))
        #if DEBUG
        // Detect OSC responses (ESC ] ...) flowing back to the remote terminal.
        // OSC 11 response = "\x1b]11;rgb:RRRR/GGGG/BBBB..." (background color report).
        if bytes.count < 200, let str = String(data: bytes, encoding: .utf8) {
            let escaped = str.unicodeScalars.map { scalar in
                scalar.value < 32 || scalar.value == 127
                    ? String(format: "\\x%02x", scalar.value)
                    : String(scalar)
            }.joined()
            if escaped.contains("\\x1b]") || escaped.contains("\\x1b[") {
                log.debug("io_write OSC/CSI response (\(bytes.count, privacy: .public) bytes): \(escaped, privacy: .public)")
            }
        }
        #endif
        GhosttySurfaceBridge.fromOpaque(userdata)?.handleWrite(bytes)
    }

    @MainActor
    static func focusInput(for surface: ghostty_surface_t) {
        view(for: surface)?.focusInput()
    }

    @MainActor
    static func setTitle(_ title: String, for surface: ghostty_surface_t) {
        view(for: surface)?.surfaceTitle = title
    }

    @MainActor
    static func ringBell(for surface: ghostty_surface_t) {
        view(for: surface)?.handleBell()
    }

    @MainActor
    static func title(for surface: ghostty_surface_t) -> String? {
        view(for: surface)?.surfaceTitle
    }

    @MainActor
    static func drawVisibleSurfacesForWakeup() {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            view.drawForWakeup()
        }
    }

    /// "What the user sees": the visible viewport text of every on-screen
    /// terminal surface, for the DEV "Copy Debug Logs" action so a bug report
    /// pairs the on-screen content with the debug log. Reads the VIEWPORT
    /// (visible grid only, not scrollback) via libghostty.
    public static func visibleTerminalSnapshot() -> String {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        var sections: [String] = []
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            guard view.window != nil, !view.isHidden, view.alpha > 0.01 else { continue }
            let grid = view.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "?"
            let text = view.renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT) ?? "(unavailable)"
            sections.append(
                "===== visible terminal · grid=\(grid) · font=\(Int(view.liveFontSize)) =====\n"
                + text
            )
        }
        if sections.isEmpty {
            return "===== visible terminal: (no on-screen surface) ====="
        }
        return sections.joined(separator: "\n\n")
    }

    private func handleBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRingBell,
            object: self
        )
    }
}

private final class WeakGhosttySurfaceViewBox {
    weak var value: GhosttySurfaceView?

    init(_ value: GhosttySurfaceView) {
        self.value = value
    }
}

private extension GhosttySurfaceView {
    @MainActor
    static var registeredSurfaceViews: [UInt: WeakGhosttySurfaceViewBox] = [:]

    @MainActor
    static func register(surface: ghostty_surface_t, for view: GhosttySurfaceView) {
        registeredSurfaceViews[surfaceIdentifier(for: surface)] = WeakGhosttySurfaceViewBox(view)
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
    }

    @MainActor
    static func unregister(surface: ghostty_surface_t) {
        registeredSurfaceViews.removeValue(forKey: surfaceIdentifier(for: surface))
    }

    @MainActor
    static func view(for surface: ghostty_surface_t) -> GhosttySurfaceView? {
        let identifier = surfaceIdentifier(for: surface)
        guard let view = registeredSurfaceViews[identifier]?.value else {
            registeredSurfaceViews.removeValue(forKey: identifier)
            return nil
        }
        return view
    }

    static func surfaceIdentifier(for surface: ghostty_surface_t) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(surface))
    }
}

private class DisplayLinkProxy {
    private weak var target: GhosttySurfaceView?

    init(target: GhosttySurfaceView) {
        self.target = target
    }

    @objc func handleDisplayLink() {
        target?.handleDisplayLinkFire()
    }
}

// MARK: - Arrow Nub (draggable directional pad)

final class TerminalArrowNubView: UIView {
    var onArrowKey: ((Data) -> Void)?

    private let nubSize: CGFloat = 34
    private let deadZone: CGFloat = 8
    private let repeatInterval: TimeInterval = 0.08
    private let innerDot = UIView()
    private var dragOrigin: CGPoint = .zero
    private var repeatTimer: Timer?
    private var lastDirection: Direction?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    private enum Direction {
        case up, down, left, right
        var escapeSequence: Data {
            switch self {
            case .up:    return Data([0x1B, 0x5B, 0x41])
            case .down:  return Data([0x1B, 0x5B, 0x42])
            case .right: return Data([0x1B, 0x5B, 0x43])
            case .left:  return Data([0x1B, 0x5B, 0x44])
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.25, alpha: 0.85)
        layer.cornerRadius = nubSize / 2

        innerDot.backgroundColor = UIColor(white: 0.85, alpha: 1)
        innerDot.layer.cornerRadius = 6
        innerDot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        innerDot.layer.shadowColor = UIColor.white.cgColor
        innerDot.layer.shadowOpacity = 0.3
        innerDot.layer.shadowRadius = 3
        innerDot.layer.shadowOffset = .zero
        addSubview(innerDot)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        feedbackGenerator.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if repeatTimer == nil {
            innerDot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: nubSize, height: nubSize)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            dragOrigin = innerDot.center
            feedbackGenerator.prepare()
        case .changed:
            let maxOffset: CGFloat = nubSize / 2 - 8
            let clampedX = max(-maxOffset, min(maxOffset, translation.x))
            let clampedY = max(-maxOffset, min(maxOffset, translation.y))
            innerDot.center = CGPoint(x: dragOrigin.x + clampedX, y: dragOrigin.y + clampedY)

            let direction = directionFrom(dx: translation.x, dy: translation.y)
            if direction != lastDirection {
                lastDirection = direction
                stopRepeat()
                if let direction {
                    fireArrow(direction)
                    startRepeat(direction)
                }
            }
        case .ended, .cancelled:
            stopRepeat()
            lastDirection = nil
            UIView.animate(withDuration: 0.15) {
                self.innerDot.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            }
        default:
            break
        }
    }

    private func directionFrom(dx: CGFloat, dy: CGFloat) -> Direction? {
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > deadZone else { return nil }
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        } else {
            return dy > 0 ? .down : .up
        }
    }

    private func fireArrow(_ direction: Direction) {
        feedbackGenerator.impactOccurred()
        onArrowKey?(direction.escapeSequence)
    }

    private func startRepeat(_ direction: Direction) {
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            self?.fireArrow(direction)
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

#endif
