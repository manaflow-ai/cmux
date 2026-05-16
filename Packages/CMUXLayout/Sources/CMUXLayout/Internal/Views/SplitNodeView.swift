import SwiftUI
import AppKit

/// Recursively renders a split node (pane or split)
struct SplitNodeView<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let node: SplitNode
    let contentBuilder: (SurfaceItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: WorkspaceLayoutConfiguration.Appearance
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15

    var body: some View {
        switch node {
        case .pane(let paneState):
            // Wrap in NSHostingController for proper layout constraints
            SinglePaneWrapper(
                pane: paneState,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle
            )

        case .split(let splitState):
            SplitContainerView(
                splitState: splitState,
                controller: controller,
                appearance: appearance,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange,
                enableAnimations: enableAnimations,
                animationDuration: animationDuration
            )
        }
    }
}

/// NSHostingView subclass that refuses to act as a window-drag handle.
///
/// CMUXLayout nests SwiftUI panes inside their own `NSHostingController` instances
/// (via `SinglePaneWrapper` and `SplitContainerView.makeHostingController`).
/// The default `NSHostingView` returned by `NSHostingController.view` inherits the
/// AppKit default of `mouseDownCanMoveWindow == true` when the view appears opaque.
/// In `presentationMode == "minimal"` (where the window has no titlebar drag region)
/// AppKit was treating clicks on pane tab bars as window-drag intents and stealing the
/// mouseUp before the SwiftUI tap gesture could fire — making split pane tabs
/// completely unclickable. Routing clicks through this subclass keeps the entire pane
/// hosting chain non-draggable so SwiftUI gesture recognizers receive every click.
final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// NSHostingController whose view is a `NonDraggableHostingView`. See the comment on
/// `NonDraggableHostingView` for the rationale — this exists so call sites can keep using
/// the controller-based lifecycle (root-view swapping, sizing options, etc.) without
/// having to construct and reparent the hosting view manually.
final class NonDraggableHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = NonDraggableHostingView(rootView: rootView)
    }
}

/// Container NSView for a pane inside SinglePaneWrapper.
class PaneDragContainerView: NSView {
    override var isOpaque: Bool { false }
    // Mirror the override on `NonDraggableHostingView` so AppKit cannot grab a window
    // drag from this container either, even before the click reaches the inner hosting
    // view. See `NonDraggableHostingView` for the full rationale.
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Bare container used by `SplitContainerView` to back NSSplitView arranged subviews.
/// Like `PaneDragContainerView`, this exists purely to suppress AppKit window-drag
/// intent so split-pane tab clicks are not consumed by drag detection in minimal mode.
final class SplitArrangedContainerView: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Wrapper that uses NSHostingController for proper AppKit layout constraints
struct SinglePaneWrapper<Content: View, EmptyContent: View>: NSViewRepresentable {
    @Environment(SplitViewController.self) private var controller
    
    let pane: PaneState
    let contentBuilder: (SurfaceItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch

    func makeNSView(context: Context) -> NSView {
        let paneView = PaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle
        )
        let hostingController = NonDraggableHostingController(rootView: paneView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        let containerView = PaneDragContainerView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.isOpaque = false
        containerView.layer?.masksToBounds = true
        containerView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        // Store hosting controller to keep it alive
        context.coordinator.hostingController = hostingController

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Hide the container when inactive so AppKit's drag routing doesn't deliver
        // drag sessions to views belonging to background workspaces.
        nsView.isHidden = !controller.isInteractive
        nsView.wantsLayer = true
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        nsView.layer?.isOpaque = false
        nsView.layer?.masksToBounds = true

        let paneView = PaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle
        )
        context.coordinator.hostingController?.rootView = paneView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var hostingController: NonDraggableHostingController<PaneContainerView<Content, EmptyContent>>?
    }
}
