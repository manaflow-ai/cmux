import AppKit
import CmuxNextDesign

/// The update card's hover popover (UPDATE-CARD): "Update <version>
/// downloaded. Click to restart and install.", "Your terminals and agents
/// keep running.", then "What's changed" with the newest changes (title,
/// author and a pull request link each) and "N more changes" linking to the
/// full release notes. Theme colors; links use the primary text color with
/// an underline (never the system blue).
final class SidebarUpdateNotesView: NSView {
    static var width: CGFloat { 300 }
    private static var padding: CGFloat { Metrics.space4 }

    var onOpenLink: ((URL) -> Void)?
    /// The pointer left the popover.
    var onPointerExit: (() -> Void)?
    private(set) var notes: SidebarUpdateCard.Notes?
    private let stack = NSStackView()
    private var labels: [(NSTextField, Role)] = []
    private var links: [(NSButton, URL)] = []

    private enum Role { case primary, secondary, heading }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let p = Self.padding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ notes: SidebarUpdateCard.Notes) {
        guard notes != self.notes else { return }
        self.notes = notes
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        labels = []
        links = []
        add(label(notes.headline, .primary, font: Typography.bodyEmphasized, lines: 3))
        let keeps = label(notes.keepsRunning, .secondary, font: Typography.caption, lines: 2)
        add(keeps)
        if let heading = notes.whatsChangedTitle {
            stack.setCustomSpacing(Metrics.space4, after: keeps)
            let title = label(heading, .heading, font: .systemFont(ofSize: Typography.caption.pointSize, weight: .semibold), lines: 1)
            add(title)
            stack.setCustomSpacing(Metrics.space2, after: title)
            for change in notes.changes { add(row(change)) }
        }
        if let more = notes.moreTitle, let url = notes.moreURL {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(Metrics.space3, after: last) }
            add(link(more, url))
        }
        applyColors()
        needsLayout = true
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    }

    private func label(_ text: String, _ role: Role, font: NSFont, lines: Int) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.maximumNumberOfLines = lines
        // Wraps up to `lines`, then truncates the last one (a truncating
        // line break mode alone would keep it to one line).
        field.lineBreakMode = .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        field.preferredMaxLayoutWidth = Self.width - 2 * Self.padding
        field.isSelectable = false
        labels.append((field, role))
        return field
    }

    /// A change: its title, then "author · #1234" with the PR as a link.
    private func row(_ change: SidebarUpdateCard.Change) -> NSView {
        let title = label(change.title, .primary, font: Typography.caption, lines: 2)
        var meta: [NSView] = []
        if let author = change.author { meta.append(label(author, .secondary, font: Typography.caption, lines: 1)) }
        if let linkTitle = change.linkTitle, let url = change.url { meta.append(link(linkTitle, url)) }
        guard !meta.isEmpty else { return title }
        let line = NSStackView(views: meta)
        line.orientation = .horizontal
        line.spacing = Metrics.space2
        let column = NSStackView(views: [title, line])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        return column
    }

    private func link(_ title: String, _ url: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(linkPressed(_:)))
        button.isBordered = false
        button.refusesFirstResponder = true
        button.setAccessibilityRole(.link)
        button.toolTip = url.absoluteString
        links.append((button, url))
        return button
    }

    @objc private func linkPressed(_ sender: NSButton) {
        guard let url = links.first(where: { $0.0 === sender })?.1 else { return }
        onOpenLink?(url)
    }

    /// Recolors in the sidebar's theme scope.
    func applyColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            for (field, role) in labels {
                field.textColor = role == .primary ? Palette.textPrimary : Palette.textSecondary
            }
            for (button, _) in links {
                button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                    .font: Typography.caption, .foregroundColor: Palette.textPrimary,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])
            }
        }
    }

    override func updateLayer() { applyColors() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) { onPointerExit?() }

    // MARK: Tests

    /// Every line as shown, top to bottom (labels and link titles).
    var shownText: [String] {
        func walk(_ view: NSView) -> [String] {
            if let field = view as? NSTextField { return [field.stringValue] }
            if let button = view as? NSButton { return [button.title] }
            if let stack = view as? NSStackView { return stack.arrangedSubviews.flatMap(walk) }
            return []
        }
        return stack.arrangedSubviews.flatMap(walk)
    }

    /// The links in order: title and destination.
    var shownLinks: [(title: String, url: URL)] { links.map { ($0.0.title, $0.1) } }

    /// Clicks the link titled `title` (tests).
    func pressLink(_ title: String) {
        guard let button = links.first(where: { $0.0.title == title })?.0 else { return }
        linkPressed(button)
    }
}
