import AppKit
import CmuxNextDesign

/// Chrome's "On-device site data" dialog: every site that stored cookies or
/// other data while the page was open, each with a delete button.
final class SiteDataWindow: PageInfoWindow {
    private let send: (PageInfoCommand) -> Void
    private let list = NSStackView()

    init(site: PageInfoSite, send: @escaping (PageInfoCommand) -> Void) {
        self.send = send
        super.init(title: PageInfoStrings.siteDataTitle, size: CGSize(width: 440, height: 420))
        setAccessibilityIdentifier("cmux.pageInfo.siteData")
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(PageInfoStyle.label(PageInfoStrings.loading, font: PageInfoStyle.bodyFont, color: PageInfoStyle.secondaryText))

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = PageInfoStyle.label(PageInfoStrings.siteDataSubtitle, font: PageInfoStyle.captionFont,
                                           color: PageInfoStyle.secondaryText, wraps: true)
        let done = NSButton(title: PageInfoStrings.done, target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        [subtitle, scroll, done].forEach(root.addSubview)
        let inset = PageInfoStyle.inset * 1.5
        NSLayoutConstraint.activate([
            subtitle.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: PageInfoStyle.spacing),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset / 2),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset / 2),
            scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -PageInfoStyle.spacing),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        contentView = root
    }

    func show(_ data: SiteDataSummary) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !data.entries.isEmpty else {
            list.addArrangedSubview(PageInfoStyle.label(PageInfoStrings.siteDataEmpty, font: PageInfoStyle.bodyFont, color: PageInfoStyle.secondaryText))
            return
        }
        for entry in data.entries {
            var details = [entry.isThirdParty ? PageInfoStrings.thirdParty : PageInfoStrings.thisSite]
            if entry.cookieCount > 0 { details.append(PageInfoStrings.cookiesOnly(entry.cookieCount)) }
            if entry.hasOtherData { details.append(PageInfoStrings.otherData) }
            let row = PageInfoRowView(symbol: "globe", title: entry.domain, subtitle: details.joined(separator: " · "),
                                      accessory: .none, interactive: false, identifier: "pageInfo.siteData.\(entry.domain)")
            row.setAccessibilityLabel(PageInfoStrings.deleteDataFor(entry.domain))
            let trash = PageInfoIconButton(symbol: "trash", label: PageInfoStrings.deleteDataFor(entry.domain)) { [weak self] in
                self?.send(.deleteSiteData(domain: entry.domain))
            }
            row.addSubview(trash)
            NSLayoutConstraint.activate([
                trash.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -PageInfoStyle.rowInset),
                trash.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    @objc private func finish() { close() }
}

/// Scroll document laid out from the top.
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
