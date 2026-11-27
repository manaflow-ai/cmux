/// A third-party screenshot or screen recording app whose save folders the
/// Screenshots pane finds by itself. Where each keeps its setting and the
/// folders it always uses are Rust's (cmux-screenshots `tools.rs`); a folder
/// shows only when it exists on this Mac.
public nonisolated enum ScreenshotTool: String, Sendable, CaseIterable, Hashable {
    case cleanShotX
    case shottr
    case xnapper
    case snagit
    case monosnap
    case skitch
    case flameshot
    case kap
    case cap
    case quickTime
}
