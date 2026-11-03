/// The result of placing a browser next to, or in the pane of, a source surface.
@MainActor
struct BrowserSplitPlacement {
    enum Strategy: String {
        case splitRight = "split_right"
        case reuseRightSibling = "reuse_right_sibling"
        case samePane = "same_pane"
    }

    let panel: BrowserPanel
    let strategy: Strategy

    var createdSplit: Bool { strategy == .splitRight }
}
