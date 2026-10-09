public import AppKit
import CmuxNextDesign

/// The browser toolbar's omnibar row without the page's buttons, for a surface that is not a
/// browser page: the New Tab page shows it on top (cx-e2aa), so Cmd-L there types an address in
/// the same omnibar a browser tab has (one implementation: `AddressBarView`, its suggestions and
/// its state machine). The bar sits at the toolbar's height, top padding and side insets; its
/// suggestion card opens flush under it, clipped to `cardClip`.
public final class OmnibarToolbarView: NSView {
    public let addressBar: AddressBarView
    /// The surface the suggestion card is clipped to (the page under the row); the window when nil.
    public weak var cardClip: NSView?

    public init(suggestionEngine: OmniboxSuggestionEngine) {
        addressBar = AddressBarView(suggestionEngine: suggestionEngine)
        super.init(frame: .zero)
        addSubview(addressBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The browser toolbar row's height on this window's pixel grid (else the main screen's).
    public var preferredHeight: CGFloat {
        OmnibarStyle.toolbarHeight(scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let inset = OmnibarStyle.toolbarInset
        addressBar.frame = NSRect(x: inset, y: OmnibarStyle.toolbarTopPadding,
                                  width: max(0, bounds.width - 2 * inset), height: OmnibarStyle.barHeight)
        addressBar.followLayout()
    }
}
