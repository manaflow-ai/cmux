import AppKit
import CmuxNextDesign

/// The notice at the bottom of the page (the WebKit fallback when Chromium cannot start, a crashed page,
/// an added extension): the app's shared toast (``CmuxToastView``) with one line of text, an optional
/// action and a close button, in the toast style the person picked (Lawrence 2026-11-13: one style, picked
/// in the Toast Playground, for every toast). It belongs to its tab's page, not the window, so the chrome
/// places it (`PageFloatingOverlays`); it never takes focus, and it waits until closed.
final class BrowserNoticeView: NSView, CmuxToastStyleFollowing {
    var onClose: (() -> Void)?
    /// The notice's one action (a button before the close button), if any.
    var action: (title: String, run: () -> Void)? {
        didSet { rebuild() }
    }
    /// Set while the close animation runs; a new notice then gets a new view.
    var isDismissing = false
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            setAccessibilityLabel(text)
            rebuild()
        }
    }
    /// The toast the notice draws, rebuilt when its text, action or the picked style changes.
    private(set) var toastView: CmuxToastView?
    private let styles: CmuxToastStyleStore

    /// - Parameter styles: The picked toast style (the shared center's), followed while the notice shows.
    init(styles: CmuxToastStyleStore = CmuxToastCenter.shared.styles) {
        self.styles = styles
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        styles.follow(self)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toastStyleDidChange(_ style: CmuxToastStyle) { rebuild() }

    private func rebuild() {
        toastView?.removeFromSuperview()
        let toast = CmuxToast(id: "browser.notice", message: text, action: action.map { CmuxToast.Action(title: $0.title) },
                              duration: CmuxToast.untilClosed)
        let view = CmuxToastView(toast: toast, style: styles.style)
        // On the page's floating overlay, not the window's toast panel: the glass samples the page.
        view.surface?.samplesBehindWindow = false
        view.onAction = { [weak self] in self?.action?.run() }
        view.onClose = { [weak self] in self?.onClose?() }
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toastView = view
    }

    /// This view's tree with each frame and any label text (diagnostics:
    /// a pill drawn without its text, cx-whr7).
    var layoutReport: [String] {
        var rows: [String] = []
        func visit(_ view: NSView, _ depth: Int) {
            let text = (view as? any ShownText).map { " \"\($0.stringValue)\" intrinsic=\($0.intrinsicContentSize.width)" } ?? ""
            rows.append(String(repeating: " ", count: depth) + "\(type(of: view)) \(view.frame)\(view.isHidden ? " hidden" : "")\(text)")
            view.subviews.forEach { visit($0, depth + 1) }
        }
        visit(self, 0)
        return rows
    }
}
