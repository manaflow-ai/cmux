import AppKit
import CmuxNextDesign

/// The code suggestion under a page's code field (plans/cmux-next/email-verification-autofill/
/// DESIGN.md "Delivery"): one row, "Fill code 482 913" over "From slack.com", in its own small
/// window, like the list macOS shows under a field for a code from Messages. It is a borderless
/// child window of the browser window in the native popup style (the page menus' glass and the one
/// popup shadow), a ``NativePopupPanel`` so it stays above the Chromium page windows, placed by
/// ``NativePopupHost`` under the field or above it.
/// It is native chrome, so page script cannot read, style or click it. It never takes the keys:
/// the page keeps typing, and the chrome's key monitor drives it (Down Arrow selects the row,
/// Return then fills, Escape declines). A click on the row fills.
final class VerificationSuggestionPanel: NativePopupPanel {
    /// The person accepted (a click on the row, or Return while it is selected).
    var onAccept: (() -> Void)?
    /// The prompt it shows.
    let prompt: BrowserPrompt
    /// Where the field is (viewport fractions); the chrome places the panel under it.
    var anchor: VerificationFieldAnchor?
    /// Down Arrow selected the row: Return now fills.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            row.isHighlighted = isSelected
            keyHint.isHidden = !isSelected
        }
    }

    private let row: PopupRowView
    private let keyHint: ThemedLabel
    private let style = PopupStyle.standard

    init(prompt: BrowserPrompt, offer: VerificationOffer) {
        self.prompt = prompt
        let icon = ThemedImageView()
        icon.image = NSImage.systemSymbol("envelope", accessibilityDescription: nil)
        icon.ink = .secondary
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: BrowserMetrics.symbolPointSize, weight: .regular)
        keyHint = ThemedLabel(labelWithString: "↩")
        keyHint.ink = .tertiary
        keyHint.font = Typography.caption
        keyHint.isHidden = true
        var layout = PopupRowView.Layout()
        layout.leadingColumn = 18
        layout.gap = 8
        let title = Strings.verificationSuggestionFill(code: offer.code.map(Self.grouped) ?? "")
        let detail = Strings.verificationSuggestionFrom(site: offer.senderSite)
        row = PopupRowView(leading: icon, title: title, subtitle: detail, trailing: keyHint, layout: layout)
        row.titleLabel.font = Typography.system(.monospacedDigit, size: Typography.body.pointSize, weight: TypeScale.regular)
        super.init(identifier: "cmux.verification-suggestion")
        row.onActivate = { [weak self] in self?.onAccept?() }

        let content = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: style.padding),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: style.padding),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: style.padding),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: style.padding),
        ])
        let surface = Glass.makeMenuPanel(content: content)
        surface.samplesBehindWindow = true
        adoptPopupStyle(card: surface)
    }

    /// The page keeps the keys: the chrome's key monitor drives the row.
    override var canBecomeKey: Bool { false }

    /// A host for this window (placement, motion, dismiss rules); the caller owns it.
    func makeHost() -> NativePopupHost { NativePopupHost(panel: self) }

    /// The card's size: the row's natural size inside the popup padding, never narrower than a
    /// page menu.
    var cardSize: CGSize {
        let fitting = row.fittingSize
        return CGSize(width: max(200, ceil(fitting.width) + 2 * style.padding),
                      height: ceil(fitting.height) + 2 * style.padding)
    }

    /// The code as it reads best: six or eight characters in two groups ("482 913").
    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<half])\u{2009}\(code[half...])"
    }
}
