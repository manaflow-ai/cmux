public import AppKit
public import CmuxNextDesign

// The Customize Inspector's hit test (CustomizeElementHit). The list answers its own rows and
// section headers (SidebarListView+CustomizeElement); what reaches the sidebar itself is a card
// (`widget`) or the sidebar (`sidebar`).
extension SidebarView: CustomizeElementPointing {
    public func customizeElement(at point: NSPoint) -> CustomizeElementHit? {
        guard bounds.contains(point) else { return nil }
        let cards: [NSView] = [nowPlayingCardView, updateCardView, updatedCardView, noticeCardView]
        for card in cards where !card.isHidden && card.window != nil {
            let frame = card.convert(card.bounds, to: self)
            if frame.contains(point) { return CustomizeElementHit(id: "widget", frame: frame) }
        }
        return CustomizeElementHit(id: "sidebar", frame: bounds)
    }
}

extension SidebarListView: CustomizeElementPointing {
    func customizeElement(at point: NSPoint) -> CustomizeElementHit? {
        guard let row = clickHit(at: point) else { return nil }
        let frame = frame(for: row)
        guard frame.contains(point) else { return nil }
        switch row.key {
        case .workspace: return CustomizeElementHit(id: "workspaceRow", frame: frame)
        case .section, .group, .folder, .status, .listHeader: return CustomizeElementHit(id: "sidebarSection", frame: frame)
        default: return nil
        }
    }
}

extension SidebarRegionView: CustomizeElementPointing {
    func customizeElement(at point: NSPoint) -> CustomizeElementHit? {
        bounds.contains(point) ? CustomizeElementHit(id: "sidebarSection", frame: bounds) : nil
    }
}
