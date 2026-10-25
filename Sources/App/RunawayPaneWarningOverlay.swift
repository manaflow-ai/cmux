import AppKit
import SwiftUI

/// Hosts the runaway-terminal banner at the top of a window's workspace
/// content. Terminal and browser portals are AppKit siblings above the
/// SwiftUI content, so a SwiftUI overlay would draw underneath them; like the
/// cloud pane failure card, the banner is a native sibling above the portals
/// and this view only anchors its geometry.
struct RunawayPaneWarningOverlay: NSViewRepresentable {
    let warning: RunawayPaneWarning?
    let onStop: (RunawayPaneWarning) -> Void
    let onDismiss: (RunawayPaneWarning) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.update(
            warning: warning,
            layoutDirection: context.environment.layoutDirection,
            colorScheme: context.environment.colorScheme,
            onStop: onStop,
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
            let warning: RunawayPaneWarning
            let width: CGFloat
            let layoutDirection: LayoutDirection
            let colorScheme: ColorScheme
        }

        private static let maximumWidth: CGFloat = 600
        private static let margin: CGFloat = 12

        weak var anchor: AnchorView?
        private var warning: RunawayPaneWarning?
        private var onStop: ((RunawayPaneWarning) -> Void)?
        private var onDismiss: ((RunawayPaneWarning) -> Void)?
        private var layoutDirection: LayoutDirection = .leftToRight
        private var colorScheme: ColorScheme = .light
        private var card: NSHostingView<AnyView>?
        private var rendered: RenderState?
        private var isSynchronizing = false
        private let chromeComposition = AppWindowChromeComposition()

        func update(
            warning: RunawayPaneWarning?,
            layoutDirection: LayoutDirection,
            colorScheme: ColorScheme,
            onStop: @escaping (RunawayPaneWarning) -> Void,
            onDismiss: @escaping (RunawayPaneWarning) -> Void
        ) {
            self.warning = warning
            self.layoutDirection = layoutDirection
            self.colorScheme = colorScheme
            self.onStop = onStop
            self.onDismiss = onDismiss
            synchronize()
        }

        func removeCard() {
            card?.removeFromSuperview()
            card = nil
            rendered = nil
        }

        func synchronize() {
            guard !isSynchronizing else { return }
            isSynchronizing = true
            defer { isSynchronizing = false }
            guard let warning, let anchor, let window = anchor.window,
                  !anchor.isHiddenOrHasHiddenAncestor,
                  let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else {
                removeCard()
                return
            }
            let bounds = target.container.convert(anchor.bounds, from: anchor)
            guard bounds.width > 120, bounds.height > 48 else {
                removeCard()
                return
            }
            let width = min(Self.maximumWidth, bounds.width - Self.margin * 2)
            let nextRender = RenderState(
                warning: warning,
                width: width,
                layoutDirection: layoutDirection,
                colorScheme: colorScheme
            )
            let host = card ?? NSHostingView(rootView: AnyView(EmptyView()))
            if card == nil {
                host.identifier = NSUserInterfaceItemIdentifier("cmux.runawayPaneWarning.card")
                host.sizingOptions = [.intrinsicContentSize]
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor.clear.cgColor
            }
            card = host
            if host.superview !== target.container {
                host.removeFromSuperview()
                // Portals install just above the content reference (or each
                // other); keep this banner above the topmost one.
                let foregroundSurface = target.container.subviews.last {
                    $0 is WindowTerminalHostView || $0 is WindowBrowserHostView
                } ?? target.reference
                target.container.addSubview(host, positioned: .above, relativeTo: foregroundSurface)
            }
            var height = host.frame.height
            if rendered != nextRender {
                host.rootView = AnyView(
                    RunawayPaneWarningBanner(
                        warning: warning,
                        onStop: { [weak self] in self?.onStop?($0) },
                        onDismiss: { [weak self] in self?.onDismiss?($0) }
                    )
                    // A new terminal's warning gets fresh banner state, so an
                    // open Stop confirmation never carries over to it.
                    .id(warning.key)
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.colorScheme, colorScheme)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                )
                height = ceil(host.fittingSize.height)
                rendered = nextRender
            }
            let topY = target.container.isFlipped ? bounds.minY + Self.margin : bounds.maxY - Self.margin - height
            let frame = NSRect(x: bounds.midX - width / 2, y: topY, width: width, height: height)
            if host.frame != frame { host.frame = frame }
        }
    }
}

/// Reads the warning center for one window, so a new sample re-renders only
/// this leaf, not the window's content view. Shows no warning while the
/// window shows something other than its workspaces.
struct RunawayPaneWarningOverlayHost: View {
    let center: RunawayPaneWarningCenter
    let workspaceIDs: Set<UUID>
    let isShowingWorkspaces: Bool

    var body: some View {
        RunawayPaneWarningOverlay(
            warning: isShowingWorkspaces
                ? center.warnings.first { workspaceIDs.contains($0.workspaceId) }
                : nil,
            onStop: { center.stopProcessTree($0) },
            onDismiss: { center.dismiss($0) }
        )
    }
}
