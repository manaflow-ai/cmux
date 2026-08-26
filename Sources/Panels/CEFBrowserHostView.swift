import AppKit
import CmuxCEF

/// Pane-anchored host for a CEF-owned browser window.
///
/// CEF chrome-style browsers render natively into their own frameless
/// NSWindow. This view occupies the pane rect and keeps that window adopted
/// as a child window exactly covering the view: same process, GPU-composited,
/// no frame streaming. Visibility and geometry follow the view; input goes
/// straight to the CEF window.
@MainActor
final class CEFBrowserHostView: NSView {
    private weak var cefWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var isAdopted = false

    /// Whether this pane currently owns the visible browser surface. CEF's
    /// child window must stay ordered out for inactive tabs/workspaces.
    var isPaneVisible = false {
        didSet {
            guard oldValue != isPaneVisible else { return }
            reconcile()
        }
    }

    var onFocus: (() -> Void)?

    /// Whether the CEF child is currently adopted over a visible pane and is
    /// safe for focus operations. Inactive panes keep the browser alive but
    /// order its child window out, so existence of the window alone is not a
    /// focus guarantee.
    var isFocusReady: Bool {
        isAdopted &&
            isPaneVisible &&
            window != nil &&
            !isHiddenOrHasHiddenAncestor &&
            cefWindow?.isVisible == true
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Attaches the CEF browser window to this pane.
    func attach(cefWindow: NSWindow) {
        self.cefWindow = cefWindow
        reconcile()
    }

    /// Detaches and hides the CEF window (pane closing or engine replacement).
    func detach() {
        if let cefWindow {
            window?.removeChildWindow(cefWindow)
            cefWindow.orderOut(nil)
        }
        cefWindow = nil
        isAdopted = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        if let hostWindow = window {
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                windowObservers.append(center.addObserver(
                    forName: name, object: hostWindow, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcile() }
                })
            }
        }
        reconcile()
    }

    override func layout() {
        super.layout()
        reconcile()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reconcile()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcile()
    }

    /// Aligns the CEF window with the current pane geometry and visibility.
    func reconcile() {
        guard let cefWindow else { return }
        guard isPaneVisible,
              let hostWindow = window,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 1, bounds.height > 1 else {
            if isAdopted {
                window?.removeChildWindow(cefWindow)
                cefWindow.orderOut(nil)
                isAdopted = false
            }
            return
        }
        let windowRect = convert(bounds, to: nil)
        let screenRect = hostWindow.convertToScreen(windowRect)
        if cefWindow.frame != screenRect {
            cefWindow.setFrame(screenRect, display: true)
        }
        if !isAdopted || cefWindow.parent !== hostWindow {
            cefWindow.parent?.removeChildWindow(cefWindow)
            hostWindow.addChildWindow(cefWindow, ordered: .above)
            isAdopted = true
        }
        // The window is created hidden and only appears once positioned
        // over the pane, so it can never flash at its initial bounds.
        if !cefWindow.isVisible {
            cefWindow.orderFront(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // The CEF window covers this view, so a click landing here means the
        // adopted window is missing; reconcile and forward focus intent.
        onFocus?()
        reconcile()
        super.mouseDown(with: event)
    }
}
