import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Mounts the latest cloud pane creation failure above one workspace's content.
struct CloudPaneCreationFailurePresentation: ViewModifier {
    let failureStore: CloudPaneCreationFailureStore
    var isWorkspaceVisible = true
    var sourceView: NSView?
    #if DEBUG
    @AppStorage("cloudPaneFailurePrototypeStyle") private var prototypeStyle = "compact-bordered"
    #endif

    private var style: CloudPaneCreationFailureView.Style {
        #if DEBUG
        CloudPaneCreationFailureView.Style(rawValue: prototypeStyle) ?? .compactBordered
        #else
        .compactBordered
        #endif
    }

    /// Adds the failure card above the workspace content when a failure exists.
    func body(content: Content) -> some View {
        content.background {
            NativeOverlay(
                failure: isWorkspaceVisible ? failureStore.failure : nil,
                sourceView: sourceView,
                style: style,
                onRetry: failureStore.canRetry ? { [weak failureStore] id in failureStore?.retry(id: id) } : nil,
                onDismiss: { [weak failureStore] id in failureStore?.dismiss(id: id) }
            )
        }
    }

    /// The anchor stays in the workspace layout; the interactive card is a
    /// native sibling above the terminal/browser portals, like the palette.
    struct NativeOverlay: NSViewRepresentable {
        let failure: CloudPaneCreationFailure?
        let sourceView: NSView?
        let style: CloudPaneCreationFailureView.Style
        let onRetry: ((UUID) -> Void)?
        let onDismiss: (UUID) -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> AnchorView {
            let view = AnchorView()
            view.coordinator = context.coordinator
            context.coordinator.anchor = view
            return view
        }

        func updateNSView(_ view: AnchorView, context: Context) {
            context.coordinator.update(
                failure: failure,
                layoutDirection: context.environment.layoutDirection,
                colorScheme: context.environment.colorScheme,
                sourceView: sourceView,
                style: style,
                onRetry: onRetry,
                onDismiss: onDismiss
            )
        }

        static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
            view.coordinator = nil
            coordinator.removeCard()
        }

        @MainActor
        final class AnchorView: NSView {
            weak var coordinator: Coordinator?
            override var isHidden: Bool {
                didSet { coordinator?.synchronize() }
            }
            override func viewWillMove(toWindow newWindow: NSWindow?) {
                if newWindow !== window { coordinator?.removeCard() }
                super.viewWillMove(toWindow: newWindow)
            }
            override func viewWillMove(toSuperview newSuperview: NSView?) {
                if newSuperview == nil { coordinator?.removeCard() }
                super.viewWillMove(toSuperview: newSuperview)
            }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                coordinator?.synchronize()
            }
            override func layout() {
                super.layout()
                coordinator?.synchronize()
            }
            override func setFrameOrigin(_ newOrigin: NSPoint) {
                super.setFrameOrigin(newOrigin)
                coordinator?.synchronize()
            }
            override func setFrameSize(_ newSize: NSSize) {
                super.setFrameSize(newSize)
                coordinator?.synchronize()
            }
        }

        @MainActor
        final class Coordinator {
            private struct RenderState: Equatable {
                let failure: CloudPaneCreationFailure
                let width: CGFloat
                let layoutDirection: LayoutDirection
                let colorScheme: ColorScheme
                let style: CloudPaneCreationFailureView.Style
            }

            weak var anchor: AnchorView?
            private var failure: CloudPaneCreationFailure?
            private var onDismiss: ((UUID) -> Void)?
            private var onRetry: ((UUID) -> Void)?
            private var layoutDirection: LayoutDirection = .leftToRight
            private var colorScheme: ColorScheme = .light
            private var card: NSHostingView<AnyView>?
            private var rendered: RenderState?
            private weak var sourceView: NSView?
            private var style: CloudPaneCreationFailureView.Style = .compactBordered
            private var geometryObservers: [NSObjectProtocol] = []
            private var observedViews: [ObjectIdentifier] = []
            private var isSynchronizing = false
            private let chromeComposition = AppWindowChromeComposition()

            func update(
                failure: CloudPaneCreationFailure?,
                layoutDirection: LayoutDirection,
                colorScheme: ColorScheme,
                sourceView: NSView?,
                style: CloudPaneCreationFailureView.Style,
                onRetry: ((UUID) -> Void)?,
                onDismiss: @escaping (UUID) -> Void
            ) {
                self.failure = failure
                self.layoutDirection = layoutDirection
                self.colorScheme = colorScheme
                self.sourceView = sourceView
                self.style = style
                self.onRetry = onRetry
                self.onDismiss = onDismiss
                synchronize()
            }

            func removeCard() {
                card?.removeFromSuperview()
                card = nil
                rendered = nil
                geometryObservers.forEach(NotificationCenter.default.removeObserver)
                geometryObservers.removeAll()
                observedViews.removeAll()
            }

            deinit { geometryObservers.forEach(NotificationCenter.default.removeObserver) }

            private func observeGeometry(from source: NSView, through container: NSView) {
                var views: [NSView] = []
                var current: NSView? = source
                while let view = current, view !== container {
                    views.append(view)
                    current = view.superview
                }
                let identities = views.map(ObjectIdentifier.init)
                guard observedViews != identities else { return }
                geometryObservers.forEach(NotificationCenter.default.removeObserver)
                geometryObservers.removeAll()
                observedViews = identities
                for view in views {
                    view.postsFrameChangedNotifications = true
                    view.postsBoundsChangedNotifications = true
                    for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                        geometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.synchronize() }
                        })
                    }
                }
            }

            func synchronize() {
                // Measuring the SwiftUI card can synchronously lay out its
                // anchor. The anchor remains the sole source of geometry.
                guard !isSynchronizing else { return }
                isSynchronizing = true
                defer { isSynchronizing = false }
                guard let failure, let anchor, let window = anchor.window, let sourceView,
                      !anchor.isHiddenOrHasHiddenAncestor,
                      sourceView.window === window, !sourceView.isHiddenOrHasHiddenAncestor,
                      let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else {
                    removeCard()
                    return
                }
                observeGeometry(from: sourceView, through: target.container)
                // The originating terminal defines placement, even if focus
                // moves while the remote request is in flight. Its native
                // content bounds exclude Bonsplit's tab and split controls.
                let bounds = target.container.convert(sourceView.visibleRect, from: sourceView)
                    .intersection(target.container.convert(target.reference.bounds, from: target.reference))
                guard !bounds.isNull, bounds.width > 32, bounds.height > 24 else {
                    removeCard()
                    return
                }
                let width = min(style == .dialog ? 320 : 360, bounds.width - 24)
                let nextRender = RenderState(failure: failure, width: width, layoutDirection: layoutDirection, colorScheme: colorScheme, style: style)
                let root = AnyView(
                    CloudPaneCreationFailureView(
                        failure: failure, style: style,
                        onRetry: onRetry == nil ? nil : { [weak self] in self?.onRetry?(failure.id) },
                        onDismiss: { [weak self] in self?.onDismiss?(failure.id) }
                    )
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.colorScheme, colorScheme)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                )
                let host = card ?? NSHostingView(rootView: root)
                if card == nil {
                    host.identifier = NSUserInterfaceItemIdentifier("cmux.cloudPaneCreationFailure.card")
                    host.sizingOptions = [.intrinsicContentSize]
                    host.wantsLayer = true
                    host.layer?.backgroundColor = NSColor.clear.cgColor
                }
                card = host
                if host.superview !== target.container {
                    host.removeFromSuperview()
                    // Portals install just above the content reference (or
                    // each other), keeping later portal mounts below this card.
                    // Palette and other foreground controls retain their order.
                    let foregroundSurface = target.container.subviews.last {
                        $0 is WindowTerminalHostView || $0 is WindowBrowserHostView
                    } ?? target.reference
                    target.container.addSubview(host, positioned: .above, relativeTo: foregroundSurface)
                }
                var height = host.frame.height
                if rendered != nextRender {
                    host.rootView = root
                    height = ceil(host.fittingSize.height)
                    rendered = nextRender
                }
                let x = bounds.midX - width / 2
                let y = bounds.midY - height / 2
                let frame = NSRect(x: x, y: y, width: width, height: height)
                if host.frame != frame { host.frame = frame }
            }
        }
    }
}

/// A workspace failure and a reserved terminal use the same responsive content.
struct CloudPaneCreationFailureView: View {
    typealias Style = CloudFailureCard.Style
    let failure: CloudPaneCreationFailure
    var style: Style = .compactBordered
    var onRetry: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        CloudFailureCard(
            title: failure.displayTitle, detail: failure.errorText,
            copyableText: failure.copyableText, style: style,
            onRetry: onRetry, onDismiss: onDismiss
        )
    }
}

/// Text takes the entire card width. The close control cannot compress the body
/// into a narrow column, and copying remains a contextual troubleshooting action.
struct CloudFailureCard: View {
    enum Style: String, Equatable { case compact, compactBordered = "compact-bordered", dialog, inline }
    let title: String
    let detail: String
    let copyableText: String
    var style: Style = .compactBordered
    var onRetry: (() -> Void)? = nil
    let onDismiss: () -> Void

    private var cornerRadius: CGFloat {
        switch style {
        case .compactBordered: 0
        case .inline: 3
        case .compact, .dialog: 9
        }
    }

    var body: some View {
        VStack(alignment: style == .dialog ? .center : .leading, spacing: 10) {
            Header(title: title, style: style, onDismiss: onDismiss)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(style == .dialog ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: style == .dialog ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button(String(localized: "common.retry", defaultValue: "Retry"), action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("CloudPaneCreationFailureRetry")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: style == .dialog ? .center : .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if style == .compactBordered {
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            } else if style != .inline {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .overlay(alignment: .leading) {
            if style == .inline { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2) }
        }
        .shadow(color: .black.opacity(style == .compact || style == .dialog ? 0.09 : 0), radius: 8, y: 3)
        .accessibilityIdentifier("CloudPaneCreationFailure")
        .cloudErrorCopyMenu(copyableText)
    }

    private struct Header: View {
        let title: String
        let style: Style
        let onDismiss: () -> Void
        var body: some View {
            VStack(spacing: 8) {
                if style == .dialog {
                    HStack {
                        Image(systemName: "terminal")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Spacer(minLength: 8)
                        DismissButton(onDismiss: onDismiss)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(style == .dialog ? .center : .leading)
                        .frame(maxWidth: .infinity, alignment: style == .dialog ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if style != .dialog { DismissButton(onDismiss: onDismiss) }
                }
            }
        }
    }

    private struct DismissButton: View {
        let onDismiss: () -> Void
        var body: some View {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .fixedSize()
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss"))
            .accessibilityLabel(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss"))
            .accessibilityIdentifier("CloudPaneCreationFailureDismiss")
        }
    }
}
