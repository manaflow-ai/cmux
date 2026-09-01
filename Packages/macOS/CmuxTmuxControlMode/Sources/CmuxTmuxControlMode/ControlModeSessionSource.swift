public import Foundation
public import CmuxTerminalCore

/// Describes how the local Ghostty renderer must handle a size change while a
/// foreign terminal remains authoritative.
public enum TerminalSessionResizePolicy: Equatable, Sendable {
    /// The source owns a shell primary screen whose wrapped rows may reflow.
    case reflow
    /// The source owns an already-painted grid, so local reflow would invent
    /// bytes that the source never emitted.
    case preserveScreen

    public var suppressesLocalReflow: Bool {
        self == .preserveScreen
    }
}

/// The source lifecycle result. A clean terminal exit and a transport or
/// protocol failure have different user meaning and must not share one
/// untyped "ended" state. Callers can offer reconnect only for failures.
public enum TerminalSessionTermination: Equatable, Sendable {
    /// The owned terminal process or session ended normally, or the user
    /// detached this client. `reason` is optional because many transports do
    /// not provide a stable exit description.
    case ended(reason: String?)
    /// The source could not establish or maintain a trustworthy byte stream.
    /// The foreign terminal may still exist and can be retried.
    case failed(reason: String)
}

/// Framing shared by every replacement-style session source.
///
/// A full frame is a new authority for the local terminal grid. Clearing the
/// old emulator state before applying it is part of the source contract, not a
/// renderer-specific convenience. Keeping the prefix here prevents tmux and
/// Herdr adapters from silently acquiring different reset semantics.
public enum TerminalSessionSnapshot {
    /// RIS followed by erase-scrollback. Both bytes are understood by the
    /// embedded Ghostty parser and are safe when the frame starts mid-session.
    public static let replacementPrefix: [UInt8] = [
        0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A,
    ]

    /// Prefix `bytes` as one replacement frame. Empty frames are valid and
    /// still clear stale rows from the previous source generation.
    public static func replacing(_ bytes: [UInt8]) -> [UInt8] {
        replacementPrefix + bytes
    }
}

/// What a control-mode terminal renderer needs from whatever owns the
/// authoritative session (local tmux today; the Mac mobile host and
/// cmuxd-remote later). The renderer is always a manual-IO Ghostty surface;
/// the source differs only in transport. See
/// `plans/feat-control-mode-terminals/DESIGN.md` in cmuxterm-hq.
public protocol TerminalSessionSource: AnyObject, Sendable {
    /// Human-readable name for the session (used for the surface title).
    var displayName: String { get }

    /// Begin the session at the given size. Delegate callbacks deliver the
    /// initial snapshot, then live output, then end-of-session. Every callback
    /// is MainActor-isolated. A source may parse on another executor, but its
    /// ordered delivery lane owns the actor hop before calling the delegate.
    func start(initialSize: TerminalSize, delegate: any TerminalSessionSourceDelegate)

    /// Forward bytes the user typed (already encoded by the local surface).
    func sendInput(_ bytes: [UInt8])

    /// Forward a physical named key when the source has a native key-table
    /// protocol. Byte-only sources may use the default no-op implementation.
    func sendNamedKey(_ name: String)

    /// Whether this source owns viewport scrolling as a semantic operation.
    /// Sources that expose only a raw terminal byte stream must leave this
    /// false so Ghostty keeps its normal mouse-scroll behavior.
    var supportsSemanticScroll: Bool { get }

    /// Whether this source can apply an exact character-grid resize to the
    /// foreign terminal. A rendered subscription may show a pane without
    /// owning its layout, so it must report false instead of translating a
    /// viewer resize into a destructive relative pane action.
    var supportsExactResize: Bool { get }

    /// Forward one semantic viewport-scroll request.
    func sendScroll(_ command: TerminalScrollCommand)

    /// Notify the source the local surface resized.
    func resize(_ size: TerminalSize)

    /// Tear the session down (detach; does not kill the server-side session).
    func stop()
}

public extension TerminalSessionSource {
    func sendNamedKey(_ name: String) {}
    var supportsSemanticScroll: Bool { false }
    var supportsExactResize: Bool { true }
    func sendScroll(_ command: TerminalScrollCommand) {}
}

/// Callbacks from a ``ControlModeSessionSource``.
public protocol TerminalSessionSourceDelegate: AnyObject, Sendable {
    /// The initial screen + scrollback snapshot, as bytes to feed into the
    /// local surface before any live output.
    @MainActor
    func controlModeSession(didProduceSnapshot bytes: [UInt8])
    /// Live bytes from the attached pane.
    @MainActor
    func controlModeSession(didProduceOutput bytes: [UInt8])
    /// The source's current resize policy. The renderer keeps its safe
    /// ``preserveScreen`` default until a source reports a policy.
    @MainActor
    func controlModeSession(didChangeResizePolicy policy: TerminalSessionResizePolicy)
    /// The session ended (detach, exit, or gateway death). `reason` is a
    /// best-effort human-readable cause.
    @MainActor
    func controlModeSession(didEndWithReason reason: String?)

    /// Reports a typed lifecycle result. The default implementation preserves
    /// compatibility with the original delegate contract by forwarding both
    /// cases to `didEndWithReason`; new callers should implement this method
    /// to keep failures distinct from clean exits.
    @MainActor
    func controlModeSession(didTerminate termination: TerminalSessionTermination)
}

public extension TerminalSessionSourceDelegate {
    @MainActor
    func controlModeSession(didChangeResizePolicy policy: TerminalSessionResizePolicy) {}

    @MainActor
    func controlModeSession(didTerminate termination: TerminalSessionTermination) {
        switch termination {
        case let .ended(reason):
            controlModeSession(didEndWithReason: reason)
        case let .failed(reason):
            controlModeSession(didEndWithReason: reason)
        }
    }
}

/// A bounded, ordered delivery lane from a source's protocol executor to its
/// UI delegate.
///
/// A gateway may parse bytes on a background executor, but the delegate is a
/// MainActor owner. Sending one independent `Task { @MainActor }` per callback
/// loses the source order at the actor boundary. This lane keeps one FIFO and
/// one consumer. All events yielded by a source's serial protocol executor are
/// therefore observed by the delegate in exactly that order.
///
/// The producer must call `enqueue` and `finish` from one serial context (the
/// gateway queue). `AsyncStream.Continuation` is safe to yield from that
/// context, and the fixed oldest-first buffer makes overload explicit: the
/// caller receives `false` and must fail the transport instead of dropping a
/// terminal frame silently.
public final class TerminalSessionSourceEventDelivery: @unchecked Sendable {
    public enum Event: Sendable {
        case snapshot([UInt8])
        case output([UInt8])
        case resizePolicy(TerminalSessionResizePolicy)
        case termination(TerminalSessionTermination)
    }

    private let continuation: AsyncStream<Event>.Continuation
    private let consumerTask: Task<Void, Never>
    private weak var delegate: (any TerminalSessionSourceDelegate)?
    private let finishLock = NSLock()
    private var didFinish = false

    public init(
        delegate: any TerminalSessionSourceDelegate,
        maximumBufferedEvents: Int = 512
    ) {
        let capacity = max(1, maximumBufferedEvents)
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        self.continuation = continuation
        self.delegate = delegate
        self.consumerTask = Task { @MainActor [weak delegate] in
            for await event in stream {
                guard let delegate else { continue }
                switch event {
                case let .snapshot(bytes):
                    delegate.controlModeSession(didProduceSnapshot: bytes)
                case let .output(bytes):
                    delegate.controlModeSession(didProduceOutput: bytes)
                case let .resizePolicy(policy):
                    delegate.controlModeSession(didChangeResizePolicy: policy)
                case let .termination(termination):
                    delegate.controlModeSession(didTerminate: termination)
                }
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    /// Enqueue one source event. A `false` result means the bounded delivery
    /// budget was exhausted or the lane has already been finished.
    @discardableResult
    public func enqueue(_ event: Event) -> Bool {
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    /// Enqueue the terminal result after all earlier events, then close the
    /// lane. If the bounded queue is full, drain the already accepted events
    /// and deliver the terminal result directly so a failure can never leave
    /// the UI stuck in `connecting`.
    public func finish(_ termination: TerminalSessionTermination) {
        finishLock.lock()
        guard !didFinish else {
            finishLock.unlock()
            return
        }
        didFinish = true
        finishLock.unlock()
        let result = continuation.yield(.termination(termination))
        continuation.finish()
        switch result {
        case .enqueued:
            return
        case .dropped, .terminated:
            break
        @unknown default:
            break
        }

        let consumerTask = self.consumerTask
        Task { @MainActor [weak delegate] in
            // The normal stream consumer drains all accepted events first.
            // The terminal event was not accepted, whether the bounded queue
            // was full or the consumer had already terminated. Report it after
            // that drain so the UI cannot remain in `connecting` forever.
            await consumerTask.value
            delegate?.controlModeSession(didTerminate: termination)
        }
    }
}

/// Compatibility names for the first tmux-only integration. New adapters use
/// the neutral names because Herdr and other session owners are not tmux
/// control-mode clients.
public typealias ControlModeSessionSource = TerminalSessionSource
public typealias ControlModeSessionDelegate = TerminalSessionSourceDelegate

/// What to attach to when starting a local tmux control-mode session.
public enum TmuxAttachTarget: Equatable, Sendable {
    /// Attach the most-recently-used session; fail if none exists.
    case mostRecent
    /// Attach the named session, creating it if it does not exist
    /// (`new-session -A -s <name>`).
    case session(String)
    /// Attach a named session and render one exact pane from it. The window id
    /// is retained for discovery and diagnostics; tmux commands address the
    /// stable pane id directly so a different active pane cannot be selected.
    case pane(sessionName: String, windowID: Int, paneID: Int)

    /// The argument vector for `tmux` (after the control-mode flag) for this target.
    public var tmuxArguments: [String] {
        switch self {
        case .mostRecent:
            return ["attach"]
        case let .session(name):
            return ["new-session", "-A", "-s", name]
        case .pane:
            return ["attach-session", "-t", targetExpression]
        }
    }

    /// A fully qualified target expression. The leading `=` forces tmux to
    /// match the session name exactly instead of applying its prefix-match
    /// rules. The window and pane IDs are server-assigned and remain stable
    /// for the life of the discovered objects.
    public var targetExpression: String {
        switch self {
        case .mostRecent:
            return ""
        case let .session(name):
            return "=\(name)"
        case let .pane(name, windowID, paneID):
            return "=\(name):@\(windowID).%\(paneID)"
        }
    }

    /// The tmux `%N` pane identifier, when this target names one pane.
    public var explicitPaneID: String? {
        guard case let .pane(_, _, paneID) = self else { return nil }
        return "%\(paneID)"
    }

    /// The tmux `@N` window identifier, when this target names one pane.
    /// `refresh-client -C @N:WxH` keeps a Harbor resize scoped to the dragged
    /// window instead of letting a client-size claim resize another window in
    /// the attached session.
    public var explicitWindowID: String? {
        guard case let .pane(_, windowID, _) = self else { return nil }
        return "@\(windowID)"
    }
}
