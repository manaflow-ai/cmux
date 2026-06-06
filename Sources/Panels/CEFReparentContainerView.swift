import AppKit

/// AppKit container that hosts CEF's embeddable browser view as a pinned subview.
final class CEFReparentContainerView: NSView {
    weak var cefPanel: CEFBrowserPanel?
    var onRequestPanelFocus: (() -> Void)?

    private weak var adoptedCEFView: NSView?
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        autoresizesSubviews = true
    }

    func adoptEmbeddableView(_ view: NSView?) {
        guard let view else { return }
        if view === adoptedCEFView, view.superview === self {
            cefPanel?.focusMountedViewIfNeeded()
            return
        }

        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        adoptedCEFView = view
        disableLayerFlatteningOnAncestors()
        resetSubviewOriginsAfterLayout()
        #if DEBUG
        cmuxDebugLog("cef.view.reparent panel=\(cefPanel?.id.uuidString.prefix(5) ?? "?") frame=\(bounds)")
        #endif
        syncCEFCoordinates()
        cefPanel?.focusMountedViewIfNeeded()
    }

    func detachEmbeddableView() {
        teardownObservers()
        guard let view = adoptedCEFView else {
            cefPanel = nil
            return
        }
        if let window = view.window,
           let firstResponderView = window.firstResponder as? NSView,
           firstResponderView === view || firstResponderView.isDescendant(of: view)
        {
            window.makeFirstResponder(nil)
        }
        view.removeFromSuperview()
        adoptedCEFView = nil
        cefPanel = nil
        #if DEBUG
        cmuxDebugLog("cef.view.detach")
        #endif
    }

    override func mouseDown(with event: NSEvent) {
        requestPanelFocus()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        requestPanelFocus()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        requestPanelFocus()
        super.otherMouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        teardownObservers()
        guard let window else { return }
        postsFrameChangedNotifications = true
        observeOn(NSView.frameDidChangeNotification, target: self)
        observeOn(NSWindow.didMoveNotification, target: window)
        observeOn(NSWindow.didResizeNotification, target: window)
        observeOn(NSWindow.didChangeScreenNotification, target: window)
        syncCEFCoordinates()
        cefPanel?.focusMountedViewIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { teardownObservers() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        syncCEFCoordinates()
        cefPanel?.focusMountedViewIfNeeded()
    }

    private func requestPanelFocus() {
        onRequestPanelFocus?()
        if let adoptedCEFView {
            window?.makeFirstResponder(adoptedCEFView)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    private func resetSubviewOriginsAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let cef = self.adoptedCEFView else { return }
            for subview in cef.subviews {
                subview.frame = cef.bounds
                subview.autoresizingMask = [.width, .height]
            }
        }
    }

    private func disableLayerFlatteningOnAncestors() {
        var current: NSView? = self
        while let view = current {
            if view.canDrawSubviewsIntoLayer {
                view.canDrawSubviewsIntoLayer = false
            }
            current = view.superview
        }
    }

    private func syncCEFCoordinates() {
        guard let window, let panel = cefPanel else { return }
        let inWindow = convert(bounds, to: nil)
        guard inWindow.width > 0, inWindow.height > 0 else { return }
        let onScreen = window.convertToScreen(inWindow)
        panel.syncRenderFrame(toScreen: onScreen)
        panel.notifyEmbedHostResized()
    }

    private func observeOn(_ name: Notification.Name, target: AnyObject) {
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: target,
            queue: .main
        ) { [weak self] _ in
            self?.syncCEFCoordinates()
        }
        observers.append(token)
    }

    private func teardownObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
