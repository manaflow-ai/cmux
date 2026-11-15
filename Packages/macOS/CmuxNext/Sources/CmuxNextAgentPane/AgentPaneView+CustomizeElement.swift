public import AppKit
public import CmuxNextDesign

// The Customize Inspector's hit test (CustomizeElementHit): the page's bottom stack (the composer
// card and what floats on it, the box the page reports for toasts) is the `chatComposer`; the rest
// of the chat is `chatMessages`. Native and synchronous: no page call per pointer move.
extension AgentPaneView: CustomizeElementPointing {
    public func customizeElement(at point: NSPoint) -> CustomizeElementHit? {
        guard bounds.contains(point) else { return nil }
        let composer = toastAvoidanceRect
        if !composer.isEmpty, composer.contains(point) { return CustomizeElementHit(id: "chatComposer", frame: composer) }
        return CustomizeElementHit(id: "chatMessages", frame: bounds)
    }
}
