import AppKit
import SwiftUI

/// Mounts the latest cloud pane creation failure above one workspace's content.
struct CloudPaneCreationFailurePresentation: ViewModifier {
    let failureStore: CloudPaneCreationFailureStore
    var isWorkspaceVisible = true
    var sourceView: NSView?
    #if DEBUG
    @AppStorage("cloudPaneFailurePrototypeStyle") private var prototypeStyle = "compact"
    #endif

    private var style: CloudPaneCreationFailureView.Style {
        #if DEBUG
        CloudPaneCreationFailureView.Style(rawValue: prototypeStyle) ?? .compact
        #else
        .compact
        #endif
    }

    /// Adds the failure card above the workspace content when a failure exists.
    func body(content: Content) -> some View {
        content.background {
            NativeOverlay(failure: isWorkspaceVisible ? failureStore.failure : nil, sourceView: sourceView, style: style) { id in
                failureStore.dismiss(id: id)
            }
        }
    }

    /// The anchor stays in the workspace layout; the interactive card is a
    /// native sibling above the terminal/browser portals, like the palette.
    private struct NativeOverlay: NSViewRepresentable {
        let failure: CloudPaneCreationFailure?
        let sourceView: NSView?
        let style: CloudPaneCreationFailureView.Style
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
            private var layoutDirection: LayoutDirection = .leftToRight
            private var colorScheme: ColorScheme = .light
            private var card: NSHostingView<AnyView>?
            private var rendered: RenderState?
            private weak var sourceView: NSView?
            private var style: CloudPaneCreationFailureView.Style = .compact
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
                onDismiss: @escaping (UUID) -> Void
            ) {
                self.failure = failure
                self.layoutDirection = layoutDirection
                self.colorScheme = colorScheme
                self.sourceView = sourceView
                self.style = style
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
                let width = min(style == .dialog ? 320 : 360, bounds.width - 32)
                let nextRender = RenderState(failure: failure, width: width, layoutDirection: layoutDirection, colorScheme: colorScheme, style: style)
                let root = AnyView(
                    CloudPaneCreationFailureView(failure: failure, style: style) { [weak self] in
                        self?.onDismiss?(failure.id)
                    }
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

/// Centered terminal failure designs. DEBUG can compare the alternatives;
/// the compact card is the release default until the design is selected.
struct CloudPaneCreationFailureView: View {
    enum Style: String, Equatable { case compact, dialog, inline }

    let failure: CloudPaneCreationFailure
    var style: Style = .compact
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch style {
            case .compact:
                CompactCard(failure: failure, onDismiss: onDismiss)
            case .dialog:
                DialogCard(failure: failure, onDismiss: onDismiss)
            case .inline:
                InlineCard(failure: failure, onDismiss: onDismiss)
            }
        }
        .accessibilityIdentifier("CloudPaneCreationFailure")
        .cloudErrorCopyMenu(failure.copyableText)
    }

    private struct Heading: View {
        var body: some View {
            Text(String(localized: "cloudPane.newTerminalFailed.shortTitle", defaultValue: "Couldn’t open terminal"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct Detail: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private struct Actions: View {
        let copyableText: String
        let onDismiss: () -> Void
        var body: some View {
            HStack(spacing: 8) {
                Button(CloudErrorCopy.title) { CloudErrorCopy.copy(copyableText) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CloudPaneCreationFailureCopy")
                Spacer(minLength: 8)
                Button(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("CloudPaneCreationFailureDismiss")
            }
            .controlSize(.small)
            .font(.system(size: 12))
        }
    }

    private struct CompactCard: View {
        let failure: CloudPaneCreationFailure
        let onDismiss: () -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Heading()
                        Detail(text: failure.errorText)
                    }
                }
                Actions(copyableText: failure.copyableText, onDismiss: onDismiss)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }

    private struct DialogCard: View {
        let failure: CloudPaneCreationFailure
        let onDismiss: () -> Void
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
                Heading()
                Detail(text: failure.errorText)
                    .multilineTextAlignment(.center)
                Divider().padding(.vertical, 2)
                Actions(copyableText: failure.copyableText, onDismiss: onDismiss)
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
        }
    }

    private struct InlineCard: View {
        let failure: CloudPaneCreationFailure
        let onDismiss: () -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Heading()
                Detail(text: failure.errorText)
                Divider().padding(.vertical, 2)
                Actions(copyableText: failure.copyableText, onDismiss: onDismiss)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2)
            }
        }
    }
}
