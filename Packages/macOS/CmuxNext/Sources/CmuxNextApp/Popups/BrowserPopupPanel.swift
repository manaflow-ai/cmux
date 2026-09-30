import AppKit
import CmuxNextBrowser
import CmuxNextDesign

/// A floating panel that shows one popup page (`window.open` with window
/// features: OAuth sign-in, payment, an extension's popup window) over its
/// opener's window. Theme chrome: the page's title and origin (so the user
/// sees which site asks for a password), the system close button, and a
/// resizable frame. It is a child of the opener's window, so it moves,
/// hides and minimizes with it. Escape the page did not use closes it
/// (`onEscape`); closing it closes the page (`onClose`).
final class BrowserPopupPanel: NSPanel {
    static let titleHeight: CGFloat = 28

    let page: any BrowserTab
    var onEscape: (() -> Void)?
    var onClose: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let originLabel = NSTextField(labelWithString: "")
    private var observation: Task<Void, Never>?

    init(page: any BrowserTab, frame: CGRect) {
        self.page = page
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        setFrame(frame, display: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.closeButton)?.toolTip = Strings.popupCloseHelp
        backgroundColor = Palette.windowBackground
        ThemeStore.shared.adopt(self)
        minSize = CGSize(width: BrowserPopupPanelGeometry.minimumContent.width,
                         height: BrowserPopupPanelGeometry.minimumContent.height + Self.titleHeight)
        animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        tabbingMode = .disallowed
        contentView = makeContent()
        observeTitle()
    }

    /// Page title and origin, live.
    private func observeTitle() {
        let page = page
        observation = Task { [weak self] in
            for await state in Observations({ page.state }) {
                self?.show(title: state.title, url: state.url)
            }
        }
    }

    private func show(title: String?, url: URL?) {
        let origin = url.flatMap(Self.origin) ?? ""
        let text = title.flatMap { $0.isEmpty ? nil : $0 } ?? (origin.isEmpty ? Strings.popupUntitled : origin)
        titleLabel.stringValue = text
        originLabel.stringValue = origin
        originLabel.isHidden = origin.isEmpty || origin == text
        self.title = text
    }

    /// `https://accounts.example.com` for a web page, the scheme for others.
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return scheme + ":" }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func makeContent() -> NSView {
        let root = NSView()
        let titleBar = NSView()
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        originLabel.font = .systemFont(ofSize: 11)
        originLabel.textColor = Palette.textSecondary
        originLabel.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [titleLabel, originLabel])
        labels.orientation = .horizontal
        labels.spacing = 6
        labels.alignment = .firstBaseline
        labels.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleBar.addSubview(labels)
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Palette.separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let pageView = page.contentView
        pageView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleBar)
        root.addSubview(separator)
        root.addSubview(pageView)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Self.titleHeight),
            // Past the close button.
            labels.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 34),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: titleBar.trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            separator.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            pageView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            pageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Escape reaches the panel only when the page did not handle it (a
    /// WebKit page passes unhandled keys up the responder chain; Chromium
    /// reports it through the shim as `.unhandledEscape`).
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    /// Every close path (close button, Escape, `window.close()`, the opener
    /// window closing) ends here once.
    override func close() {
        observation?.cancel()
        observation = nil
        let closed = onClose
        onClose = nil
        super.close()
        closed?()
    }
}
