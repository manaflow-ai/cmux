import AppKit
import SwiftUI

/// Mounts the latest cloud pane creation failure above one workspace's content.
struct CloudPaneCreationFailurePresentation: ViewModifier {
    let failureStore: CloudPaneCreationFailureStore
    var isWorkspaceVisible = true

    /// Adds the failure card above the workspace content when a failure exists.
    func body(content: Content) -> some View {
        content.background {
            NativeOverlay(failure: isWorkspaceVisible ? failureStore.failure : nil) { id in
                failureStore.dismiss(id: id)
            }
        }
    }

    /// The anchor stays in the workspace layout; the interactive card is a
    /// native sibling above the terminal/browser portals, like the palette.
    private struct NativeOverlay: NSViewRepresentable {
        let failure: CloudPaneCreationFailure?
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
            }

            weak var anchor: AnchorView?
            private var failure: CloudPaneCreationFailure?
            private var onDismiss: ((UUID) -> Void)?
            private var layoutDirection: LayoutDirection = .leftToRight
            private var colorScheme: ColorScheme = .light
            private var card: NSHostingView<AnyView>?
            private var rendered: RenderState?
            private var isSynchronizing = false
            private let chromeComposition = AppWindowChromeComposition()

            func update(
                failure: CloudPaneCreationFailure?,
                layoutDirection: LayoutDirection,
                colorScheme: ColorScheme,
                onDismiss: @escaping (UUID) -> Void
            ) {
                self.failure = failure
                self.layoutDirection = layoutDirection
                self.colorScheme = colorScheme
                self.onDismiss = onDismiss
                synchronize()
            }

            func removeCard() {
                card?.removeFromSuperview()
                card = nil
                rendered = nil
            }

            func synchronize() {
                // Measuring the SwiftUI card can synchronously lay out its
                // anchor. The anchor remains the sole source of geometry.
                guard !isSynchronizing else { return }
                isSynchronizing = true
                defer { isSynchronizing = false }
                guard let failure, let anchor, let window = anchor.window,
                      !anchor.isHiddenOrHasHiddenAncestor,
                      let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else {
                    removeCard()
                    return
                }
                let bounds = target.container.convert(anchor.bounds, from: anchor)
                    .intersection(target.container.convert(target.reference.bounds, from: target.reference))
                guard !bounds.isNull, bounds.width > 32, bounds.height > 24 else {
                    removeCard()
                    return
                }
                let width = min(420, bounds.width - 32)
                let nextRender = RenderState(failure: failure, width: width, layoutDirection: layoutDirection, colorScheme: colorScheme)
                let root = AnyView(
                    CloudPaneCreationFailureView(failure: failure) { [weak self] in
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
                let x = layoutDirection == .rightToLeft ? bounds.minX + 16 : bounds.maxX - 16 - width
                let y = target.container.isFlipped ? bounds.minY + 12 : bounds.maxY - 12 - height
                let frame = NSRect(x: x, y: y, width: width, height: height)
                if host.frame != frame { host.frame = frame }
            }
        }
    }
}

/// An inline, dismissible failure card for a cloud terminal creation request.
struct CloudPaneCreationFailureView: View {
    let failure: CloudPaneCreationFailure
    let onDismiss: () -> Void

    /// Renders the failure, recovery guidance, and dismissal action.
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.errorText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text(failure.recoveryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(CloudErrorCopy.title) {
                        CloudErrorCopy.copy(failure.copyableText)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("CloudPaneCreationFailureCopy")
                    Spacer()
                    Button(String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK")) {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("CloudPaneCreationFailureDismiss")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityIdentifier("CloudPaneCreationFailure")
        .cloudErrorCopyMenu(failure.copyableText)
    }
}
