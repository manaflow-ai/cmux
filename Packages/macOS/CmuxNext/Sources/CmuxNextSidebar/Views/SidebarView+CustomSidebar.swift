import AppKit
import CmuxNextDesign

/// The custom sidebar (plans/cmux-next/custom-sidebar-DESIGN.md): the script's view takes the
/// list's frame once its first scene is ready. While it loads, or after it fails, the native list
/// shows, so a broken script never leaves the window without navigation.
extension SidebarView {
    func installCustomSidebar(replacing old: (any SidebarCustomContent)?) {
        if let old, old !== customSidebar {
            old.onChange = nil
            old.view.removeFromSuperview()
        }
        if let content = customSidebar, content.view.superview !== self {
            content.view.isHidden = true
            SidebarPerfCounters.add(.customSidebarMounts)
            addSubview(content.view, positioned: .above, relativeTo: edgeFade)
            content.onChange = { [weak self] in self?.needsLayout = true }
        }
        needsLayout = true
    }

    func layoutCustomSidebar(in frame: NSRect) {
        let shows = customSidebar.map { $0.isReady && $0.errorText == nil } ?? false
        if let view = customSidebar?.view {
            view.frame = frame
            if view.isHidden == shows { view.isHidden = !shows }
        }
        if scrollView.isHidden != shows {
            if shows { SidebarPerfCounters.add(.customSidebarShown) }
            scrollView.isHidden = shows
            edgeFade.isHidden = shows
        }
    }
}
