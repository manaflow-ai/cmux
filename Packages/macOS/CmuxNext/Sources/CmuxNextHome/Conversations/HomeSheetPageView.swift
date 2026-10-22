public import AppKit
import CmuxNextDesign

/// A Home sheet's card (New Chief…) as the content of a page tab instead of a sheet over Home
/// (Leo 2026-10-21, "Chief: sheet as workspace"): the card sits at the top of the pane on the
/// pane's content background, centered while the pane is wider than it and from the leading edge
/// while it is narrower. Cancel and a finished action reach the card's `onFinish`; the page's owner
/// closes the tab there (`HomeSheetController.close` ends nothing else outside a sheet).
///
/// The card's Return and Escape buttons (`CmuxDialogKeyHint`) are key equivalents of their window.
/// In a sheet that window is the sheet's own; here it is the main window, so they act only while
/// the keyboard is in this page, and a terminal or chat beside it keeps its Return and Escape.
public final class HomeSheetPageView: NSView {
    /// The New Chief page tab's title.
    public static var newChiefTitle: String { HomeConversationStrings.chiefTitle }

    public let sheet: HomeSheetController
    private let background = ThemeChangeView()

    public init(sheet: HomeSheetController) {
        self.sheet = sheet
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        background.wantsLayer = true
        background.onThemeChange = { [weak background] in
            guard let background else { return }
            background.layer?.backgroundColor = background.performWithTheme { Palette.contentBackground.cgColor }
        }
        background.onThemeChange?()
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        let card = sheet.view
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = Metrics.panelCornerRadius
        card.layer?.masksToBounds = true
        addSubview(card)
        let centered = card.centerXAnchor.constraint(equalTo: centerXAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            centered,
        ])
        setAccessibilityIdentifier("cmux.home.sheetPage")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The card's distance from the top of the pane.
    public static var topInset: CGFloat { Metrics.space6 * 2 }

    /// The card's first editable field (New Chief: its name), the page's primary input.
    public var firstField: NSTextField? { Self.firstEditableField(in: sheet.view) }

    /// The window's keyboard is in this page (a field being edited counts: its field editor is inside it).
    public var ownsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ownsKeyboard else { return false }
        return super.performKeyEquivalent(with: event)
    }

    static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, !field.isHidden { return field }
        for subview in view.subviews {
            if let field = firstEditableField(in: subview) { return field }
        }
        return nil
    }
}
