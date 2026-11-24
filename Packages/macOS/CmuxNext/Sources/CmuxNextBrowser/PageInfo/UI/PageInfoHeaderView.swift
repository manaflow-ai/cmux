import AppKit
import CmuxNextDesign

/// Bubble header: the site name (main page) or back button, subpage title
/// and site (subpages), plus the close button.
final class PageInfoHeaderView: NSView {
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    /// - Parameters:
    ///   - title: the site's name on the main page, the subpage's title on a subpage.
    ///   - subtitle: a subpage's site name, under its title.
    ///   - showsBack: a subpage: the back button leads the header.
    init(title: String, subtitle: String?, showsBack: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The site's name keeps its end (its registrable domain and port) when it is too long.
        let titleView: NSView
        if showsBack {
            let titleLabel = PageInfoStyle.label(title, font: PageInfoStyle.titleFont, color: PageInfoStyle.headerText)
            titleLabel.lineBreakMode = .byTruncatingMiddle
            titleView = titleLabel
        } else {
            titleView = PageInfoSiteNameView(name: title, font: PageInfoStyle.titleFont, color: PageInfoStyle.headerText)
        }
        var lines = [titleView]
        if let subtitle {
            lines.append(PageInfoSiteNameView(name: subtitle, font: PageInfoStyle.captionFont, color: PageInfoStyle.secondaryText))
        }
        let texts = NSStackView(views: lines)
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        let close = PageInfoIconButton(symbol: "xmark", label: PageInfoStrings.close) { [weak self] in self?.onClose?() }
        addSubview(texts)
        addSubview(close)
        let look = PageInfoStyle.look
        // A redraw's header is one row tall at least, its buttons centered in it; the band's sits
        // inside the band's padding.
        let edge = look?.headerIsBand == true ? DesignTokens.space2 : 0
        var constraints = [
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edge),
            look == nil ? close.topAnchor.constraint(equalTo: topAnchor) : close.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -PageInfoStyle.spacing),
            texts.centerYAnchor.constraint(equalTo: close.centerYAnchor).prioritized(.defaultLow),
            texts.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: texts.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: close.bottomAnchor),
        ]
        if showsBack {
            let back = PageInfoIconButton(symbol: Self.backSymbol(rightToLeft: NSApp.userInterfaceLayoutDirection == .rightToLeft), label: PageInfoStrings.back) { [weak self] in self?.onBack?() }
            addSubview(back)
            constraints += [
                back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edge),
                look == nil ? back.topAnchor.constraint(equalTo: topAnchor) : back.centerYAnchor.constraint(equalTo: centerYAnchor),
                texts.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: PageInfoStyle.spacing),
            ]
        } else {
            constraints.append(texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: look?.rowLeading ?? PageInfoStyle.rowInset))
        }
        if let look { constraints.append(heightAnchor.constraint(greaterThanOrEqualToConstant: look.headerHeight)) }
        NSLayoutConstraint.activate(constraints)
    }

    /// The back button's arrow: it points at the leading edge, where the button sits, the way
    /// ``PageInfoController/backKey(rightToLeft:)`` goes back.
    static func backSymbol(rightToLeft: Bool) -> String {
        rightToLeft ? "arrow.right" : "arrow.left"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
