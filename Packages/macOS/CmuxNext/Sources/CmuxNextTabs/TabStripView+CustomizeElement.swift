public import AppKit
public import CmuxNextDesign

// The Customize Inspector's hit test (CustomizeElementHit): a tab under the point is the `tab`
// element, the rest of the strip is the `tabBar`. Same hit area as a click (`tabID(at:)`).
extension TabStripView: CustomizeElementPointing {
    public func customizeElement(at point: NSPoint) -> CustomizeElementHit? {
        guard bounds.contains(point) else { return nil }
        if let id = tabID(at: point), let cell = cells[id] {
            return CustomizeElementHit(id: "tab", frame: tabsClip.convert(cell.frame, to: self))
        }
        return CustomizeElementHit(id: "tabBar", frame: bounds)
    }
}
