@_spi(CmuxHostTransport) import CMUXExtensionClient
import AppKit
import SwiftUI

@MainActor
final class CMUXSidebarExtensionBrowserPanel: NSObject, Panel, ObservableObject {
    let id = UUID()
    let panelType: PanelType = .extensionBrowser
    let browserViewController: NSViewController

    private let title: String

    var displayTitle: String { title }
    var displayIcon: String? { "puzzlepiece.extension" }

    init(title: String) {
        self.title = title
        self.browserViewController = CMUXSidebarExtensionBrowserPresenter.makeViewController(title: title)
        super.init()
    }

    func close() {}

    func focus() {
        guard let window = browserViewController.view.window else { return }
        _ = window.makeFirstResponder(browserViewController.view)
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}

struct CMUXSidebarExtensionBrowserPanelView: NSViewControllerRepresentable {
    let panel: CMUXSidebarExtensionBrowserPanel
    let onRequestPanelFocus: () -> Void

    func makeNSViewController(context: Context) -> NSViewController {
        CMUXSidebarExtensionBrowserContainerViewController(
            browserViewController: panel.browserViewController,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        guard let container = nsViewController as? CMUXSidebarExtensionBrowserContainerViewController else {
            return
        }
        container.browserViewController.title = panel.displayTitle
        container.onRequestPanelFocus = onRequestPanelFocus
        container.attachBrowserIfNeeded()
        container.updateLayoutForCurrentBounds()
    }

    static func dismantleNSViewController(
        _ nsViewController: NSViewController,
        coordinator: ()
    ) {
        (nsViewController as? CMUXSidebarExtensionBrowserContainerViewController)?.detachBrowserForTransientReparent()
    }
}

@MainActor
private final class CMUXSidebarExtensionBrowserContainerViewController: NSViewController {
    private final class RootView: NSView {
        var onLayout: (() -> Void)?
        var onMoveToWindow: (() -> Void)?

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            onLayout?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }

    private final class FocusCardView: NSView {
        var onMouseDown: (() -> Void)?

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            onMouseDown?()
            super.mouseDown(with: event)
        }
    }

    let browserViewController: NSViewController
    var onRequestPanelFocus: () -> Void

    private let rootView = RootView(frame: .zero)
    private let cardView = FocusCardView(frame: .zero)
    private let contentView = NSView(frame: .zero)
    private var cardWidthConstraint: NSLayoutConstraint?
    private var cardHeightConstraint: NSLayoutConstraint?
    private var cardTopConstraint: NSLayoutConstraint?
    private var cardHorizontalSafetyConstraints: [NSLayoutConstraint] = []
    private var cardBottomSafetyConstraint: NSLayoutConstraint?
    private var browserConstraints: [NSLayoutConstraint] = []

    init(
        browserViewController: NSViewController,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.browserViewController = browserViewController
        self.onRequestPanelFocus = onRequestPanelFocus
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.onLayout = { [weak self] in
            self?.updateLayoutForCurrentBounds()
        }
        rootView.onMoveToWindow = { [weak self] in
            self?.attachBrowserIfNeeded()
            self?.updateLayoutForCurrentBounds()
        }

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(Self.backgroundAlpha).cgColor
        cardView.layer?.cornerRadius = Self.cornerRadius
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.borderWidth = 0
        cardView.layer?.masksToBounds = true
        cardView.onMouseDown = { [weak self] in
            self?.onRequestPanelFocus()
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        rootView.addSubview(cardView)
        cardView.addSubview(contentView)
        let cardWidthConstraint = cardView.widthAnchor.constraint(equalToConstant: Self.defaultWidth)
        let cardHeightConstraint = cardView.heightAnchor.constraint(equalToConstant: Self.defaultHeight)
        let cardTopConstraint = cardView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.topInset)
        let cardBottomSafetyConstraint = cardView.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -Self.bottomInset)
        cardWidthConstraint.priority = .defaultHigh
        cardHeightConstraint.priority = .defaultHigh
        cardHorizontalSafetyConstraints = [
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: Self.sideInset),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -Self.sideInset),
        ]
        self.cardWidthConstraint = cardWidthConstraint
        self.cardHeightConstraint = cardHeightConstraint
        self.cardTopConstraint = cardTopConstraint
        self.cardBottomSafetyConstraint = cardBottomSafetyConstraint

        NSLayoutConstraint.activate(
            cardHorizontalSafetyConstraints + [
            cardView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            cardTopConstraint,
            cardBottomSafetyConstraint,
            cardWidthConstraint,
            cardHeightConstraint,
            contentView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: cardView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])

        view = rootView
        attachBrowserIfNeeded()
    }

    func attachBrowserIfNeeded() {
        guard isViewLoaded else { return }

        if browserViewController.parent !== self {
            if browserViewController.parent != nil {
                browserViewController.removeFromParent()
            }
            browserViewController.view.removeFromSuperview()

            addChild(browserViewController)
            browserViewController.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(browserViewController.view)
            browserConstraints = [
                browserViewController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                browserViewController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                browserViewController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                browserViewController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ]
            NSLayoutConstraint.activate(browserConstraints)
        } else if browserViewController.view.superview !== contentView {
            NSLayoutConstraint.deactivate(browserConstraints)
            browserViewController.view.removeFromSuperview()
            browserViewController.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(browserViewController.view)
            browserConstraints = [
                browserViewController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                browserViewController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                browserViewController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                browserViewController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ]
            NSLayoutConstraint.activate(browserConstraints)
        }

        browserViewController.view.wantsLayer = true
        browserViewController.view.layer?.cornerRadius = Self.cornerRadius
        browserViewController.view.layer?.cornerCurve = .continuous
        browserViewController.view.layer?.masksToBounds = true
    }

    func detachBrowserForTransientReparent() {
        guard browserViewController.parent === self else { return }
        NSLayoutConstraint.deactivate(browserConstraints)
        browserConstraints = []
        browserViewController.view.removeFromSuperview()
        browserViewController.removeFromParent()
    }

    func updateLayoutForCurrentBounds() {
        cardWidthConstraint?.constant = Self.width(for: rootView.bounds.width)
        cardHeightConstraint?.constant = Self.height(for: rootView.bounds.height)
        cardTopConstraint?.constant = Self.topInset
        cardBottomSafetyConstraint?.constant = -Self.bottomInset
        cardHorizontalSafetyConstraints.first?.constant = Self.sideInset
        cardHorizontalSafetyConstraints.dropFirst().first?.constant = -Self.sideInset

        cardView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(Self.backgroundAlpha).cgColor
        cardView.layer?.cornerRadius = Self.cornerRadius
        browserViewController.view.layer?.cornerRadius = Self.cornerRadius
    }

    private static func width(for availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return defaultWidth }
        return min(defaultWidth, max(minWidth, availableWidth - sideInset * 2))
    }

    private static func height(for availableHeight: CGFloat) -> CGFloat {
        guard availableHeight > 0 else { return defaultHeight }
        return min(maxHeight, max(minHeight, min(defaultHeight, availableHeight - topInset - bottomInset)))
    }

    private static let sideInset: CGFloat = 20
    private static let topInset: CGFloat = 16
    private static let bottomInset: CGFloat = 16
    private static let minWidth: CGFloat = 260
    private static let defaultWidth: CGFloat = 720
    private static let minHeight: CGFloat = 360
    private static let defaultHeight: CGFloat = 460
    private static let maxHeight: CGFloat = 560
    private static let cornerRadius: CGFloat = 8
    private static let backgroundAlpha: CGFloat = 0.35
}
