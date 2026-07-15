import AppKit

@MainActor
final class SidebarInteractiveScroller: NSScroller {
  var onPointerPresenceChanged: ((Bool) -> Void)?
  var onInteractionChanged: ((Bool) -> Void)?
  private var pointerTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
    }
    super.updateTrackingAreas()
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [
        .activeInKeyWindow,
        .enabledDuringMouseDrag,
        .inVisibleRect,
        .mouseEnteredAndExited,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    pointerTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    onPointerPresenceChanged?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onPointerPresenceChanged?(false)
  }

  override func mouseDown(with event: NSEvent) {
    onInteractionChanged?(true)
    defer { onInteractionChanged?(false) }
    super.mouseDown(with: event)
  }
}
