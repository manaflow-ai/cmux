public import CmuxNextDesignTokens

/// How a page resizes while its pane springs (a split, a close, a zoom), with the app's
/// `pageSpringResizeOnce` feature on (Debug Settings `browserResize.springPageResize`).
public nonisolated enum SpringPageResize: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// Once, at the spring's start: the page takes the size it rests at, held at its top-left, and the gap
    /// beside it shows the page's background. Chromium sizes a tab once and fills the gap with the page's
    /// gutter color the same way (`content/browser/renderer_host/delegated_frame_host.h`).
    case once
    /// With its pane on every frame whose size changes, to compare.
    case perFrame

    public var tunableTitle: String {
        switch self {
        case .once: "Once at the spring's start"
        case .perFrame: "On every frame"
        }
    }
}

/// What pages in a pane do while it springs (``RestingPlacement/pageResizing``): nil on a placement keeps
/// today's behavior, a page resizing with its pane. A hosted Chromium page's resize joins the fence of the
/// turn that made it (one fence per geometry transaction), so the one resize at a spring's
/// start shows with the spring's first frame.
public struct PageSpringResizing {
    /// The mode, read at each spring's start (a Debug Settings edit applies to the next spring).
    public let mode: () -> SpringPageResize

    public init(mode: @escaping () -> SpringPageResize) {
        self.mode = mode
    }
}
