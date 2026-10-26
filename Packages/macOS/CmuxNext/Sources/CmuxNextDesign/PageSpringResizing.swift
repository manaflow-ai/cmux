public import CmuxNextDesignTokens

/// How a page resizes while its pane springs (a split, a close, a zoom), with the app's
/// `pageSpringResizeOnce` feature on (Debug Settings `browserResize.springPageResize`, p03-rendering-036).
public nonisolated enum SpringPageResize: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// Once, at the spring's start: the page takes the size it rests at, held at its top-left, and the gap
    /// beside it shows the page's background. Chromium sizes a tab once and fills the gap with the page's
    /// gutter color the same way (`content/browser/renderer_host/delegated_frame_host.h`).
    case once
    /// With its pane on every frame whose size changes, each resize of a hosted Chromium page fenced, to compare.
    case perFrame

    public var tunableTitle: String {
        switch self {
        case .once: "Once at the spring's start"
        case .perFrame: "On every frame"
        }
    }
}

/// What pages in a pane do while it springs (``RestingPlacement/pageResizing``): nil on a placement keeps
/// today's behavior, a page resizing with its pane.
public struct PageSpringResizing {
    /// The mode, read at each spring's start (a Debug Settings edit applies to the next spring).
    public let mode: () -> SpringPageResize
    /// The window's resize fence of the current run-loop turn, shared by every page of the window.
    public let fence: ResizeFenceTurn

    public init(mode: @escaping () -> SpringPageResize, fence: ResizeFenceTurn) {
        self.mode = mode
        self.fence = fence
    }
}

/// One resize fence per run-loop turn of a window (p03-rendering-036 with 042 and 043): the first page
/// resized in a turn opens a fence port on the window's Core Animation context, every page resized in
/// that turn joins it, and the port goes after the turn's commit. The render server then holds the
/// window's frame until each page's frame at its new size arrives or its deadline passes, so a spring's
/// first frame and the pages' new sizes show together and the main thread never waits (Chrome's surface
/// synchronization: `cc/layers/deadline_policy.h` `UseSpecifiedDeadline`,
/// `components/viz/service/surfaces/surface.h`).
@MainActor
public final class ResizeFenceTurn {
    /// The window context's fence calls (task 043): a seam, so tests count fences without a context.
    public struct Port {
        /// Creates a fence port and sets it on the transaction being built; nil when none could open.
        public let open: () -> UInt32?
        /// Lets a port go after the transaction that carries it committed.
        public let release: (UInt32) -> Void

        public init(open: @escaping () -> UInt32?, release: @escaping (UInt32) -> Void) {
            self.open = open
            self.release = release
        }
    }

    /// The frames a fenced page may hold the window's frame for (Chrome's `UseSpecifiedDeadline(2)`).
    public static let deadlineFrames: UInt32 = 2

    /// The context's calls; nil until the app's context has them (task 043): nothing is fenced, and a
    /// resized page shows its last frame until its new one comes.
    public var port: Port?
    private let afterCommit: (@escaping @MainActor () -> Void) -> Void
    private var current: UInt32?
    /// Fences opened so far: one per turn that resized a hosted page.
    public private(set) var opened = 0

    /// - Parameter afterCommit: runs a block after the current pass's commit (`AfterFrameCommit`).
    public init(port: Port? = nil, afterCommit: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.port = port
        self.afterCommit = afterCommit
    }

    /// The fence a page resized in this turn joins, opened by the first one; nil without a port.
    public func fence() -> UInt32? {
        if let current { return current }
        guard let port, let opened = port.open() else { return nil }
        current = opened
        self.opened += 1
        afterCommit { [weak self] in
            self?.current = nil
            port.release(opened)
        }
        return opened
    }
}
