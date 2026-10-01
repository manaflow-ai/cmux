/// The result of placing a browser in its owning split tree.
@MainActor
struct BrowserSplitPlacement {
    enum Strategy: String {
        case samePane = "same_pane"
        case reuseRightSibling = "reuse_right_sibling"
        case splitRight = "split_right"
    }

    let panel: BrowserPanel
    let strategy: Strategy
    var createdSplit: Bool { strategy == .splitRight }
}
