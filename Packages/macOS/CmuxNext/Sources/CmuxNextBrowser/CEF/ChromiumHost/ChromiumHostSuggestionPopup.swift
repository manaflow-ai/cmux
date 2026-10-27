import AppKit
import CmuxNextDesign

/// The cmux popup a page view's suggestions show in (``ChromiumHostSuggestionList``): a child panel
/// of the window in the popup style, placed and dismissed by the shared ``NativePopupHost`` as the
/// page menus past the window's edge are (``WebPopupHost``). Below the field, or above it when the
/// screen has no room below, as Chrome places its popup (`CalculatePopupBounds`,
/// chrome/browser/ui/autofill/autofill_popup_view_utils.cc), with its leading edge on the field's
/// (its trailing edge for a right-to-left field), as wide as the field within ``minWidth`` and
/// ``maxWidth``. It opens in one frame: the person is typing in the field.
final class ChromiumHostSuggestionPopup: ChromiumHostSuggestionPresenting {
    var onHover: ((Int?) -> Void)?
    var onPick: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    /// A narrow field still gets rows that can be read; a wide one gets a list no wider than a menu.
    static let minWidth: CGFloat = 164
    static let maxWidth: CGFloat = 456

    private lazy var panel = ChromiumHostSuggestionPanel(
        onHover: { [weak self] row in self?.onHover?(row) },
        onPick: { [weak self] row in self?.onPick?(row) },
        onRemove: { [weak self] row in self?.onRemove?(row) }
    )
    private lazy var popup = makePopup()

    private func makePopup() -> NativePopupHost {
        let popup = NativePopupHost(panel: panel)
        // A click outside the rows closes them, the field's too, as one outside Chrome's popup does.
        popup.onDismiss = { [weak self] in self?.onDismiss?() }
        return popup
    }

    /// The card's frame on the screen, nil while hidden.
    var shownFrame: CGRect? { popup.isShown ? popup.cardFrame : nil }

    func present(_ suggestions: ChromiumHostSuggestions, highlighted: Int?, field: CGRect, in window: NSWindow) -> Bool {
        panel.rows.update(suggestions.rows, highlighted: highlighted)
        let width = min(max(field.width, Self.minWidth), Self.maxWidth)
        let size = CGSize(width: width, height: panel.rows.contentHeight)
        let placed = popup.show(size: size, anchor: field, in: window, preferred: .below, trailing: suggestions.rightToLeft, entrance: false)
        return placed != nil
    }

    func highlight(_ row: Int?) {
        panel.rows.highlight(row)
    }

    func hide() {
        popup.hide()
    }
}

/// The child panel a page's suggestions show in. Page content, like the page's own windows
/// (``ContentChildPanel``): never key, so the field keeps the keys, and below every cmux overlay.
final class ChromiumHostSuggestionPanel: ContentChildPanel {
    let rows: ChromiumHostSuggestionRows

    init(onHover: @escaping (Int?) -> Void, onPick: @escaping (Int) -> Void, onRemove: @escaping (Int) -> Void) {
        rows = ChromiumHostSuggestionRows(onHover: onHover, onPick: onPick, onRemove: onRemove)
        super.init()
        identifier = NSUserInterfaceItemIdentifier("cmux.page-suggestions")
        // Rows the screen cannot fit scroll, as Chrome's popup rows do.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.follow(scroll)
        scroll.documentView = rows
        let surface = Glass.makeOverlayPanel(content: scroll, cornerRadius: PopupStyle.standard.cornerRadius)
        adoptPopupStyle(card: surface)
    }
}
