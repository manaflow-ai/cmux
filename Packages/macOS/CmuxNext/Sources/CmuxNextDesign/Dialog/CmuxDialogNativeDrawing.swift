public import AppKit

/// Draws every cmux dialog with AppKit (``CmuxDialogView``): the overlay host's drawing by default. Each shown
/// dialog gets one region view with its card, kept for the dialog's whole life (a tab switch shows the same
/// view again) and dropped when the dialog ends. The card is drawn as it is made, so the host fades in a
/// drawn card at once (``CmuxDialogDrawing/whenDrawn(_:_:)``'s default).
@MainActor
public final class CmuxDialogNativeDrawing: CmuxDialogDrawing {
    private var regions: [ObjectIdentifier: CmuxDialogRegionView] = [:]

    public init() {}

    public func attach(_ dialog: CmuxDialogPresentation, in window: NSWindow?) -> NSView? {
        if let region = regions[ObjectIdentifier(dialog)] { return region }
        let card = CmuxDialogView(dialog: dialog)
        dialog.renderer = card
        let region = CmuxDialogRegionView(card: card)
        region.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.region")
        regions[ObjectIdentifier(dialog)] = region
        return region
    }

    public func focus(_ dialog: CmuxDialogPresentation) {
        regions[ObjectIdentifier(dialog)]?.card.focusInitial()
    }

    public func detach(_ dialog: CmuxDialogPresentation) {
        regions.removeValue(forKey: ObjectIdentifier(dialog))
    }
}
