import AppKit
import CmuxChief

/// The settings panel's Memory list: the five newest notes Chief remembered,
/// one line each at 11 pt with a relative time, a ✕ on hover that forgets the
/// note, and "Show All…" for the memory sheet (P1-5; reference
/// `apps/aside/web/memory-file-browser.jpg`: inspectable, deletable memory).
/// Live: it re-reads after every change to the memory files.
@MainActor
final class ChiefMemorySectionView: NSView {
    static let shownCount = 5

    private let width: CGFloat
    private let rows = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: ChiefMemoryStrings.sectionEmpty)
    private let showAllButton = NSButton(title: ChiefMemoryStrings.showAll, target: nil, action: nil)
    private let outer = NSStackView()
    private var theme = ChiefTheme.current()
    private var observer: (any NSObjectProtocol)?

    /// Show All… was clicked: the host opens the memory sheet.
    var onShowAll: () -> Void = {}

    /// - Parameter width: The section's fixed width (the panel's content width).
    init(width: CGFloat) {
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.preferredMaxLayoutWidth = width
        showAllButton.target = self
        showAllButton.action = #selector(showAll)
        showAllButton.bezelStyle = .push
        showAllButton.controlSize = .regular
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        for view in [rows, emptyLabel, showAllButton] as [NSView] { outer.addArrangedSubview(view) }
        addSubview(outer)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.widthAnchor.constraint(equalToConstant: width),
            showAllButton.widthAnchor.constraint(equalToConstant: width),
        ])
        observer = NotificationCenter.default.addObserver(forName: ChiefMemoryStore.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() } // main-proof: observer on queue: .main
        }
        ChiefMemoryStore.shared.start()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // Not an isolated deinit (Swift 6.0 has none): the main-thread check guards the hop.
    deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Relative times age while the panel is closed.
        if window != nil {
            ChiefMemoryStore.shared.start()
            reload()
        }
    }

    /// Shows the newest notes again.
    func reload() {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let recent = ChiefMemoryStore.shared.recent(Self.shownCount)
        for fact in recent {
            let row = ChiefMemoryNoteRow(fact: fact, width: width, compact: true)
            row.onForget = { [weak self] id in
                // Keep the small settings list responsive even when the file
                // watcher is coalescing a burst of edits. `forget` remains the
                // single mutation path and its notification updates other views.
                _ = ChiefMemoryStore.shared.forget(id)
                self?.reload()
            }
            row.apply(theme)
            rows.addArrangedSubview(row)
        }
        emptyLabel.isHidden = !recent.isEmpty
        rows.isHidden = recent.isEmpty
        // The settings panel sizes its stack by frame: lay it out again for the new height.
        superview?.needsLayout = true
        superview?.superview?.needsLayout = true
    }

    func apply(_ theme: ChiefTheme) {
        self.theme = theme
        emptyLabel.textColor = theme.textTertiary
        for case let row as ChiefMemoryNoteRow in rows.arrangedSubviews { row.apply(theme) }
    }

    @objc private func showAll() { onShowAll() }
}

/// One remembered note: the text on one line (truncated, full text in the
/// tooltip), its time and source, and a ✕ that forgets it. The ✕ shows on
/// hover; it stays in the accessibility tree, and the row also offers
/// "Forget" as a VoiceOver action.
@MainActor
final class ChiefMemoryNoteRow: NSView {
    let fact: ChiefMemoryFact
    private let text = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let forgetButton = NSButton()
    private var hoverArea: NSTrackingArea?
    private var hovering = false { didSet { updateHover() } }
    private var theme = ChiefTheme.current()
    private let compact: Bool

    /// The ✕ was clicked: forget the note with this id.
    var onForget: (String) -> Void = { _ in }
    /// The pencil was clicked (sheet rows only).
    var onEdit: (ChiefMemoryFact) -> Void = { _ in }

    /// - Parameters:
    ///   - compact: The settings list (11 pt, one line, time only) rather than the sheet's notes list.
    init(fact: ChiefMemoryFact, width: CGFloat, compact: Bool) {
        self.fact = fact
        self.compact = compact
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: compact ? 22 : 40))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        let size: CGFloat = compact ? 11 : 13
        text.stringValue = fact.text
        text.font = .systemFont(ofSize: size)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.truncatesLastVisibleLine = true
        text.toolTip = fact.text
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let time = ChiefMemoryStrings.relative(fact.createdAt)
        meta.stringValue = compact ? time : "\(ChiefMemoryStrings.source(fact.source)) · \(time)"
        meta.font = .systemFont(ofSize: compact ? 11 : 11)
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        meta.setContentHuggingPriority(.required, for: .horizontal)
        meta.toolTip = DateFormatter.localizedString(from: fact.createdAt, dateStyle: .medium, timeStyle: .short)
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: ChiefMemoryStrings.editNote)
        editButton.imagePosition = .imageOnly
        editButton.isBordered = false
        editButton.target = self
        editButton.action = #selector(editClicked)
        editButton.toolTip = ChiefMemoryStrings.editNote
        editButton.setAccessibilityLabel(ChiefMemoryStrings.editNote)
        editButton.isHidden = compact
        forgetButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: ChiefMemoryStrings.forget)
        forgetButton.imagePosition = .imageOnly
        forgetButton.isBordered = false
        forgetButton.target = self
        forgetButton.action = #selector(forgetClicked)
        forgetButton.toolTip = ChiefMemoryStrings.forgetHelp(fact.text)
        forgetButton.setAccessibilityLabel(ChiefMemoryStrings.forgetHelp(fact.text))
        forgetButton.alphaValue = compact ? 0 : 1
        for view in [text, meta, editButton, forgetButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: compact ? 22 : 42),
            forgetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            forgetButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forgetButton.widthAnchor.constraint(equalToConstant: 16),
            forgetButton.heightAnchor.constraint(equalToConstant: 16),
            editButton.trailingAnchor.constraint(equalTo: forgetButton.leadingAnchor, constant: -4),
            editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 16),
            editButton.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: compact ? 4 : 10),
        ]
        if compact {
            constraints += [
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
                meta.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
                meta.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -4),
                text.trailingAnchor.constraint(lessThanOrEqualTo: meta.leadingAnchor, constant: -6),
            ]
        } else {
            constraints += [
                text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                text.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -8),
                meta.leadingAnchor.constraint(equalTo: text.leadingAnchor),
                meta.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(fact.text), \(meta.stringValue)")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: ChiefMemoryStrings.forget) { [weak self] in
            self?.forgetClicked()
            return true
        }])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func accessibilityChildren() -> [Any]? { compact ? [forgetButton] : [editButton, forgetButton] }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    func apply(_ theme: ChiefTheme) {
        self.theme = theme
        text.textColor = theme.textPrimary
        meta.textColor = theme.textTertiary
        forgetButton.contentTintColor = theme.textSecondary
        updateHover()
    }

    private func updateHover() {
        // The settings list is narrow and has no reliable hover affordance on
        // trackpads. Keep Forget visible there so a note can always be removed;
        // the full memory sheet still uses hover to keep its rows quiet.
        forgetButton.alphaValue = compact ? 1 : (hovering ? 1 : 0)
        layer?.backgroundColor = hovering ? theme.hoverFill.cgColor : nil
    }

    @objc private func editClicked() { onEdit(fact) }
    @objc private func forgetClicked() { onForget(fact.id) }
}
