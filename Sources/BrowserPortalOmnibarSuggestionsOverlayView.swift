import AppKit

/// Full-slot event-routing overlay for the native address-bar suggestions popup.
@MainActor
final class BrowserPortalOmnibarSuggestionsOverlayView: NSView {
    private let popupView: OmnibarSuggestionsView
    private(set) var popupFrameInTopLeftCoordinates: CGRect = .zero

    override var isFlipped: Bool { true }

    init(configuration: BrowserPortalOmnibarSuggestionsConfiguration) {
        popupView = OmnibarSuggestionsView(
            engineName: configuration.engineName,
            items: configuration.items,
            selectedIndex: configuration.selectedIndex,
            isLoadingRemoteSuggestions: configuration.isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: configuration.searchSuggestionsEnabled,
            colorScheme: configuration.colorScheme,
            onCommit: configuration.onCommit,
            onHighlight: configuration.onHighlight
        )
        popupFrameInTopLeftCoordinates = configuration.popupFrame
        super.init(frame: .zero)
        addSubview(popupView)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: BrowserPortalOmnibarSuggestionsConfiguration) {
        popupFrameInTopLeftCoordinates = configuration.popupFrame
        popupView.update(
            engineName: configuration.engineName,
            items: configuration.items,
            selectedIndex: configuration.selectedIndex,
            isLoadingRemoteSuggestions: configuration.isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: configuration.searchSuggestionsEnabled,
            colorScheme: configuration.colorScheme,
            onCommit: configuration.onCommit,
            onHighlight: configuration.onHighlight
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        popupView.frame = popupFrameInTopLeftCoordinates
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        guard popupFrameInTopLeftCoordinates.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }
}
