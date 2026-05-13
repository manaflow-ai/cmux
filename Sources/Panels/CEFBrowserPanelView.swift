import AppKit
import SwiftUI

/// SwiftUI host for ``CEFBrowserPanel``. The parallel to
/// ``BrowserPanelView`` for the experimental CEF engine.
///
/// v1 scope: render the CEF browser's content NSView inside the cmux
/// pane area with a minimal browser toolbar, close to the existing
/// WKWebView chrome. Find / popup UI come in follow-up PRs. The pane
/// background and any cmux pane chrome live in the surrounding view
/// tree (same as ``BrowserPanelView``).
struct CEFBrowserPanelView: View {
    @ObservedObject var panel: CEFBrowserPanel
    let paneId: Any
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var activationError: Error?
    @State private var addressText: String = ""
    @FocusState private var addressFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            ZStack {
                if let error = activationError {
                    fallbackView(for: error)
                } else {
                    CEFContentRepresentable(panel: panel, revision: panel.activationRevision)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: isVisibleInUI) {
            if addressText.isEmpty {
                addressText = panel.addressBarDisplayString
            }
            guard isVisibleInUI else { return }
            do {
                try panel.activate()
            } catch {
                activationError = error
            }
        }
        .onChange(of: panel.currentURL) { _, newURL in
            guard !addressFieldFocused else { return }
            addressText = newURL?.absoluteString ?? panel.addressBarDisplayString
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            browserToolbarButton(
                systemImage: "chevron.left",
                help: String(localized: "cefBrowserPanel.back", defaultValue: "Back"),
                isEnabled: panel.canGoBack,
                action: panel.goBack)

            browserToolbarButton(
                systemImage: "chevron.right",
                help: String(localized: "cefBrowserPanel.forward", defaultValue: "Forward"),
                isEnabled: panel.canGoForward,
                action: panel.goForward)

            browserToolbarButton(
                systemImage: panel.isLoading ? "xmark" : "arrow.clockwise",
                help: panel.isLoading
                    ? String(localized: "cefBrowserPanel.stop", defaultValue: "Stop loading")
                    : String(localized: "cefBrowserPanel.reload", defaultValue: "Reload"),
                action: {
                    if panel.isLoading {
                        panel.stopLoading()
                    } else {
                        panel.reload()
                    }
                })

            addressPill

            browserToolbarButton(
                systemImage: "antenna.radiowaves.left.and.right",
                help: String(localized: "cefBrowserPanel.remoteDebugStatus", defaultValue: "Remote debugging"),
                action: {})
            .disabled(true)

            browserToolbarButton(
                systemImage: "person.circle",
                help: String(localized: "cefBrowserPanel.profile", defaultValue: "Profile"),
                action: {})
            .disabled(true)

            browserToolbarButton(
                systemImage: "circle.lefthalf.filled",
                help: String(localized: "cefBrowserPanel.appearance", defaultValue: "Appearance"),
                action: {})
            .disabled(true)

            browserToolbarButton(
                systemImage: "wrench.and.screwdriver",
                help: String(localized: "cefBrowserPanel.devTools", defaultValue: "DevTools"),
                action: panel.showDevTools)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 1)
        }
    }

    private var addressPill: some View {
        HStack(spacing: 6) {
            Image(systemName: isSecureURL ? "lock.fill" : "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            TextField(
                String(
                    localized: "cefBrowserPanel.addressPlaceholder",
                    defaultValue: "Search or enter address"),
                text: $addressText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .focused($addressFieldFocused)
            .onSubmit(commitAddressBar)
            .onChange(of: addressFieldFocused) { _, isFocused in
                if isFocused {
                    addressText = panel.addressBarDisplayString
                } else {
                    addressText = panel.currentURL?.absoluteString ?? panel.addressBarDisplayString
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.38))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    private var isSecureURL: Bool {
        let raw = addressFieldFocused ? addressText : panel.addressBarDisplayString
        return URL(string: raw)?.scheme == "https"
    }

    @ViewBuilder
    private func browserToolbarButton(
        systemImage: String,
        help: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(CEFBrowserToolbarButtonStyle())
        .disabled(!isEnabled)
        .help(help)
    }

    private func commitAddressBar() {
        guard let url = normalizedURL(from: addressText) else {
            addressText = panel.currentURL?.absoluteString ?? panel.addressBarDisplayString
            return
        }
        addressText = url.absoluteString
        panel.load(url)
    }

    private func normalizedURL(from text: String) -> URL? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if let url = URL(string: raw), url.scheme != nil {
            return url
        }

        if raw.contains("."),
           !raw.contains(" "),
           let url = URL(string: "https://\(raw)")
        {
            return url
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: raw)]
        return components.url
    }

    @ViewBuilder
    private func fallbackView(for error: Error) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
            Text(error.localizedDescription)
                .font(.callout)
                .multilineTextAlignment(.center)
            Text(String(
                localized: "cefBrowserPanel.fallbackHint",
                defaultValue: "Switch back to WKWebView from Debug → Browser Engine."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CEFBrowserToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed
                        ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                        : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

/// SwiftUI bridge that reparents the CEF browser's `embeddableView`
/// (a `BridgedContentView` extracted from `CefBrowserView`) into the
/// cmux pane — exactly the integration path validated by
/// `CMUXCEFDemoApp` (`addPane` in `CEF/Sources/CMUXCEFDemoApp/main.swift`).
///
/// Lifecycle:
///   * `makeNSView` creates an empty container.
///   * `updateNSView` reparents `panel.embeddableView` into the container
///     once `panel.activate()` has produced one (signalled via
///     `panel.activationRevision`).
///   * `CEFReparentContainerView` keeps CEF's compositor coordinates in
///     sync on resize / window move (`browser.syncRenderFrame`), mirroring
///     `PaneContainerView.syncCEFCoordinates` in the demo.
private struct CEFContentRepresentable: NSViewRepresentable {
    let panel: CEFBrowserPanel
    let revision: Int

    func makeNSView(context: Context) -> CEFReparentContainerView {
        let container = CEFReparentContainerView()
        container.cefPanel = panel
        return container
    }

    func updateNSView(_ container: CEFReparentContainerView, context: Context) {
        container.cefPanel = panel
        container.adoptEmbeddableView(panel.embeddableView)
    }

    static func dismantleNSView(_ container: CEFReparentContainerView, coordinator: ()) {
        container.detachEmbeddableView()
    }
}

/// Plain AppKit container that hosts the CEF `embeddableView` as a
/// pinned subview. Forces the un-flipped Cocoa coordinate space
/// Chromium's compositor assumes, and pushes its on-screen frame back
/// to CEF on every layout / window-move so hit-testing stays aligned.
private final class CEFReparentContainerView: NSView {
    weak var cefPanel: CEFBrowserPanel?
    private weak var adoptedCEFView: NSView?
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { false }

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

    /// Reparent the CEF `embeddableView` into this container if we haven't
    /// already. Idempotent — safe to call from `updateNSView` on every
    /// SwiftUI pass.
    func adoptEmbeddableView(_ view: NSView?) {
        guard let view = view else { return }
        if view === adoptedCEFView, view.superview === self { return }

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
        // Chromium's internal subviews (WebContentsViewCocoa,
        // RenderWidgetHostViewCocoa) inherit a stale frame from CEF's
        // initial 4000x4000 offscreen window — typically y=296 inside the
        // BridgedContentView even after Auto Layout sizes the outer view.
        // AppKit then delivers mouse events to those subviews using their
        // actual frame.origin, so clicks register ~200 px below the user's
        // pointer until something kicks Chromium to relayout. We reset the
        // sublayout once the container has a real size.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let cef = self.adoptedCEFView else { return }
            for sub in cef.subviews {
                sub.frame = cef.bounds
                sub.autoresizingMask = [.width, .height]
            }
        }
        #if DEBUG
        cmuxDebugLog("cef.view.reparent panel=\(cefPanel?.id.uuidString.prefix(5) ?? "?") frame=\(bounds)")
        #endif
        syncCEFCoordinates()
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

    #if DEBUG
    private func dumpLayerTree(view: NSView, label: String) {
        guard let layer = view.layer else {
            cmuxDebugLog("cef.layerdump.\(label) NO_LAYER")
            return
        }
        let sub = (layer.sublayers ?? []).enumerated().map { i, l in
            "[\(i):\(type(of: l)) frame=\(l.frame) contents=\(l.contents == nil ? "nil" : "set") sublayers=\(l.sublayers?.count ?? 0)]"
        }.joined(separator: " ")
        cmuxDebugLog("cef.layerdump.\(label) layer=\(type(of: layer)) frame=\(layer.frame) sublayers=\(sub)")
    }

    static func dumpLayerRecursive(_ layer: CALayer, prefix: String, depth: Int, maxDepth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let contentsDesc: String
        if let c = layer.contents {
            contentsDesc = "set:\(type(of: c))"
        } else {
            contentsDesc = "nil"
        }
        let maskDesc = layer.mask != nil ? "mask=YES" : "mask=NO"
        cmuxDebugLog("cef.\(prefix)\(depth) \(indent)\(type(of: layer)) frame=\(layer.frame) cScale=\(layer.contentsScale) clip=\(layer.masksToBounds) \(maskDesc) opac=\(layer.opacity) hidden=\(layer.isHidden) contents=\(contentsDesc) sublayers=\(layer.sublayers?.count ?? 0)")
        if depth >= maxDepth { return }
        for sub in (layer.sublayers ?? []) {
            dumpLayerRecursive(sub, prefix: prefix, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    static func dumpAncestorLayers(of view: NSView, prefix: String) {
        var cur: NSView? = view.superview
        var depth = 0
        while let v = cur, depth < 10 {
            if let layer = v.layer {
                let maskDesc = layer.mask != nil ? "mask=YES" : "mask=NO"
                cmuxDebugLog("cef.\(prefix)\(depth) \(type(of: v)) frame=\(v.frame) layerClip=\(layer.masksToBounds) layerHidden=\(layer.isHidden) layerOpac=\(layer.opacity) \(maskDesc) viewHidden=\(v.isHidden)")
            } else {
                cmuxDebugLog("cef.\(prefix)\(depth) \(type(of: v)) NO_LAYER")
            }
            cur = v.superview
            depth += 1
        }
    }

    static func dumpViewSubviews(_ view: NSView, prefix: String, depth: Int, maxDepth: Int) {
        let indent = String(repeating: "  ", count: depth)
        cmuxDebugLog("cef.\(prefix)\(depth) \(indent)\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden) flipped=\(view.isFlipped) layer=\(view.layer.map { String(describing: type(of: $0)) } ?? "nil")")
        if depth >= maxDepth { return }
        for sub in view.subviews {
            dumpViewSubviews(sub, prefix: prefix, depth: depth + 1, maxDepth: maxDepth)
        }
    }
    #endif

    #if DEBUG
    private func describeHostingChain() -> String {
        var labels: [String] = []
        var cur: NSView? = superview
        var depth = 0
        while let v = cur, depth < 8 {
            labels.append("\(type(of: v))[layer=\(v.wantsLayer ? "Y" : "N"),flatten=\(v.canDrawSubviewsIntoLayer ? "Y" : "N")]")
            cur = v.superview
            depth += 1
        }
        return labels.joined(separator: "←")
    }
    #endif

    /// Walk up the AppKit superview chain and disable
    /// `canDrawSubviewsIntoLayer`. SwiftUI's `NSHostingView` flips this on
    /// by default; with it enabled, AppKit rasterises every descendant
    /// CALayer into the host view's backing store. Chromium delivers
    /// rendered frames as IOSurface-backed CALayer content on the
    /// `BridgedContentView`'s layer tree — that delivery is dropped on
    /// the floor when an ancestor flattens.
    static func resetSubviewOrigins(of view: NSView?) {
        guard let v = view else { return }
        for sub in v.subviews where sub.frame.origin != .zero {
            var f = sub.frame
            f.origin = .zero
            sub.frame = f
        }
    }

    private func disableLayerFlatteningOnAncestors() {
        var cur: NSView? = self
        while let v = cur {
            if v.canDrawSubviewsIntoLayer {
                v.canDrawSubviewsIntoLayer = false
            }
            cur = v.superview
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        teardownObservers()
        guard let window = self.window else { return }
        postsFrameChangedNotifications = true
        observeOn(NSView.frameDidChangeNotification, target: self)
        observeOn(NSWindow.didMoveNotification, target: window)
        observeOn(NSWindow.didResizeNotification, target: window)
        observeOn(NSWindow.didChangeScreenNotification, target: window)
        syncCEFCoordinates()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { teardownObservers() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        syncCEFCoordinates()
    }

    private func syncCEFCoordinates() {
        guard let window = self.window, let panel = cefPanel else { return }
        let inWin = convert(bounds, to: nil)
        guard inWin.width > 0, inWin.height > 0 else { return }
        let onScreen = window.convertToScreen(inWin)
        panel.syncRenderFrame(toScreen: onScreen)
    }

    private func observeOn(_ name: Notification.Name, target: AnyObject) {
        let token = NotificationCenter.default.addObserver(
            forName: name, object: target, queue: .main
        ) { [weak self] _ in
            self?.syncCEFCoordinates()
        }
        observers.append(token)
    }

    private func teardownObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }
}
