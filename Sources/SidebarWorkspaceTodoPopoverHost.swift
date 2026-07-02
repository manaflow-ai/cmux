import AppKit
import SwiftUI

/// Hosts a workspace-todo popover (the glyph's status popover and the
/// checklist popover) in a real NSPopover. SwiftUI's native `.popover()`
/// doesn't reliably let an embedded TextField become first responder in
/// cmux's focus-managed environment because the terminal keeps grabbing
/// focus back; the checklist popover's add-item field needs one.
///
/// Follows the `SectionPopoverHost` pattern in `SessionIndexView.swift`:
/// - DO NOT set `sizingOptions = [.preferredContentSize]` on the hosting
///   controller. That makes NSHostingController continuously rewrite its
///   preferredContentSize from SwiftUI layout; NSPopover observes it and
///   overrides any manual `popover.contentSize`, latching onto a partial
///   first-pass height and rendering squished. `contentSize` is driven
///   manually from `fittingSize` on every update/present instead.
/// - `presentationCount` bumps the SwiftUI view identity on each
///   hidden-to-shown transition so every open gets fresh view-local state.
/// - While shown, the root view is rebuilt only when the Equatable `model`
///   actually changes, so unrelated parent re-renders don't re-lay-out the
///   popover (the 100% CPU loop behind #3010).
struct SidebarWorkspaceTodoPopoverHost<Model: Equatable, PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// The value snapshot the popover renders. Rebuilding the content is
    /// keyed off this changing, so include everything the body reads.
    let model: Model
    var minWidth: CGFloat = 200
    var maxHeight: CGFloat = 480
    var preferredEdge: NSRectEdge = .maxX
    /// Builds the popover body from the latest model; the second argument
    /// closes the popover (footer buttons, Return/Esc handling).
    let content: (Model, @escaping @MainActor () -> Void) -> PopoverContent

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.minWidth = minWidth
        coordinator.maxHeight = maxHeight
        coordinator.preferredEdge = preferredEdge
        coordinator.update(model: model) { model, close in
            AnyView(content(model, close))
        }
        if isPresented {
            coordinator.present()
        } else {
            coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        weak var anchorView: NSView?
        var minWidth: CGFloat = 200
        var maxHeight: CGFloat = 480
        var preferredEdge: NSRectEdge = .maxX

        private let hostingController: NSHostingController<AnyView> = {
            NSHostingController(rootView: AnyView(EmptyView()))
            // DO NOT set sizingOptions here — see the type comment.
        }()
        private var popover: NSPopover?
        private var currentModel: Model?
        private var currentBuilder: ((Model, @escaping @MainActor () -> Void) -> AnyView)?
        private var lastRenderedModel: Model?
        private var lastRenderedPresentationCount: Int?
        /// Bumped on every hidden-to-shown transition; used as the SwiftUI
        /// view identity so each open gets fresh view-local state.
        private var presentationCount = 0

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func update(
            model: Model,
            builder: @escaping (Model, @escaping @MainActor () -> Void) -> AnyView
        ) {
            currentModel = model
            currentBuilder = builder
            // When hidden, defer rebuilding the hosting view until present().
            guard popover?.isShown == true else { return }
            guard lastRenderedModel != model
                || lastRenderedPresentationCount != presentationCount else { return }
            refreshContent()
        }

        private func refreshContent() {
            guard let model = currentModel, let builder = currentBuilder else { return }
            let identity = presentationCount
            hostingController.rootView = AnyView(
                builder(model) { [weak self] in
                    self?.closeFromContent()
                }
                .id(identity)
            )
            lastRenderedModel = model
            lastRenderedPresentationCount = presentationCount
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            updateContentSize()
        }

        func present() {
            guard let anchorView, anchorView.window != nil else {
                isPresented = false
                return
            }
            anchorView.superview?.layoutSubtreeIfNeeded()
            let popover = popover ?? makePopover()
            // Only bump identity on a hidden-to-shown transition; bumping on
            // every updateNSView would reset view-local state on every tick.
            if !popover.isShown {
                presentationCount += 1
                refreshContent()
            }
            updateContentSize()
            guard !popover.isShown else { return }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: preferredEdge)
        }

        func dismiss() {
            popover?.performClose(nil)
        }

        func closeFromContent() {
            isPresented = false
            dismiss()
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.contentViewController = hostingController
            p.delegate = self
            self.popover = p
            return p
        }

        private func updateContentSize() {
            let fitting = hostingController.view.fittingSize
            guard fitting.width > 0, fitting.height > 0 else { return }
            popover?.contentSize = NSSize(
                width: ceil(max(fitting.width, minWidth)),
                height: ceil(min(fitting.height, maxHeight))
            )
        }
    }
}
