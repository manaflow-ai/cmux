public import AppKit
public import CmuxNextDesign

// The goo look (Debug `chrome.gooMorph`, `GooMorphChrome`): in its pool looks the sidebar is a card under the
// window's top band, with the + as its droplet.
extension SidebarContainerView: GooSidebarSource {
    public var gooShowsCard: Bool { !model.isHidden && model.style != .rail }
    public var gooNewButtonInWindow: (frame: CGRect, alpha: CGFloat)? { sidebarView.newButtonInWindow }
    public var gooNewButtonRow: (() -> (midY: CGFloat, height: CGFloat)?)? {
        get { sidebarView.newButtonRow }
        set { sidebarView.newButtonRow = newValue }
    }
}
