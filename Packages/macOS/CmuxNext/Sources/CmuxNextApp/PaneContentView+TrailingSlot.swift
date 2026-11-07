import AppKit
import CmuxNextDesign

// The tab row's trailing slot (`PaneTrailingSlots`): the strip gives up the most any tab of the pane takes at the row's
// trailing end, so opening, closing or selecting a tab moves neither the tabs nor the toolbar and a chat's tools.
extension PaneContentView {
    /// Points the strip gives up at the row's trailing end: what the selected tab takes now (`tools`: its toolbar and
    /// its page's tools in the row), or more where another tab of the pane takes more. Records the selected tab's need
    /// while its own content shows (not an outgoing page a paint hold keeps, nor a key resize's hold).
    func trailingSlot(shown: CGFloat, held: Bool, tools: CGFloat) -> CGFloat {
        guard shown > 0 else { return tools }
        let model = stripView.model
        if !held, hostsContent, paintHold.kept == nil, let id = model.selectedID, let view = toolbar?.view {
            let sharer = barPosition == .top && !isBandActive ? content as? PaneTabRowSharing : nil
            let need = PaneTrailingSlots.Need(intrinsic: view.intrinsicContentSize.width,
                                              shared: sharer == nil ? nil : view.tabRowWidth,
                                              tools: sharer?.tabRowToolsNeed)
            trailingSlots.record(need, for: id, live: model.tabs)
        }
        return max(tools, trailingSlots.reserve(in: bounds.width, besides: model.selectedID))
    }
}
