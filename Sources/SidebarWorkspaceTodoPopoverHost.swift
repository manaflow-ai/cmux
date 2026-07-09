import AppKit
import SwiftUI

/// Invisible popover content view that promotes the popover window to key as
/// soon as AppKit attaches it, so real controls receive keyboard input.
struct PopoverKeyWindowElevator: NSViewRepresentable {
    struct PromotionResult {
        let hasWindow: Bool
        let canBecomeKey: Bool
        let wasKeyWindow: Bool
        let isKeyWindow: Bool
        let windowVisible: Bool
        let occlusionVisible: Bool
        let appActive: Bool
        let keyWindowKind: String
    }

    final class KeyElevatingView: NSView {
        private var occlusionObserver: NSObjectProtocol?

        deinit {
            removeOcclusionObserver()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeOcclusionObserver()
            guard let window else { return }
            let promotion = PopoverKeyWindowElevator.promoteToKeyIfPossible(window)
#if DEBUG
            PopoverKeyWindowElevator.logPromotion("focus.todoPopover.elevator", promotion)
#endif
            guard promotion.canBecomeKey,
                  !promotion.isKeyWindow,
                  !promotion.occlusionVisible else { return }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: nil
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let window = notification.object as? NSWindow else { return }
                    guard window.occlusionState.contains(.visible) else { return }
#if DEBUG
                    let retry = PopoverKeyWindowElevator.promoteToKeyIfPossible(window)
                    PopoverKeyWindowElevator.logPromotion("focus.todoPopover.elevator.visible", retry)
#else
                    _ = PopoverKeyWindowElevator.promoteToKeyIfPossible(window)
#endif
                    self.removeOcclusionObserver()
                }
            }
        }

        private func removeOcclusionObserver() {
            guard let occlusionObserver else { return }
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
    }

    func makeNSView(context: Context) -> NSView {
        KeyElevatingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @discardableResult
    static func promoteToKeyIfPossible(_ window: NSWindow?) -> PromotionResult {
        guard let window else {
            return PromotionResult(
                hasWindow: false,
                canBecomeKey: false,
                wasKeyWindow: false,
                isKeyWindow: false,
                windowVisible: false,
                occlusionVisible: false,
                appActive: NSApp.isActive,
                keyWindowKind: String(describing: NSApp.keyWindow.map { type(of: $0) })
            )
        }
        let wasKeyWindow = window.isKeyWindow
        let canBecomeKey = window.canBecomeKey
        if canBecomeKey, !wasKeyWindow {
            window.makeKey()
        }
        return PromotionResult(
            hasWindow: true,
            canBecomeKey: canBecomeKey,
            wasKeyWindow: wasKeyWindow,
            isKeyWindow: window.isKeyWindow,
            windowVisible: window.isVisible,
            occlusionVisible: window.occlusionState.contains(.visible),
            appActive: NSApp.isActive,
            keyWindowKind: String(describing: NSApp.keyWindow.map { type(of: $0) })
        )
    }

#if DEBUG
    static func logPromotion(_ prefix: String, _ promotion: PromotionResult) {
        cmuxDebugLog(
            "\(prefix) windowPresent=\(promotion.hasWindow) "
                + "canBecomeKey=\(promotion.canBecomeKey) "
                + "keyBefore=\(promotion.wasKeyWindow) keyAfter=\(promotion.isKeyWindow) "
                + "windowVisible=\(promotion.windowVisible) "
                + "occlusionVisible=\(promotion.occlusionVisible) "
                + "appActive=\(promotion.appActive) "
                + "keyWindowKind=\(promotion.keyWindowKind)"
        )
    }
#endif
}

/// Hosts workspace-todo popovers that need the generic NSPopover lifecycle:
/// the sidebar checklist popover and the todo pane header's status popover.
/// SwiftUI's native `.popover()` doesn't reliably let an embedded TextField
/// become first responder in cmux's focus-managed environment because the
/// terminal keeps grabbing focus back; the checklist popover's add-item field
/// needs one.
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

        func popoverDidShow(_ notification: Notification) {
#if DEBUG
            let promotion = PopoverKeyWindowElevator.promoteToKeyIfPossible(hostingController.view.window)
            PopoverKeyWindowElevator.logPromotion("focus.todoPopover.didShow", promotion)
#else
            _ = PopoverKeyWindowElevator.promoteToKeyIfPossible(hostingController.view.window)
#endif
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
