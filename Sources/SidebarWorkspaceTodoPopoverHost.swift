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
    /// Explicit "user asked for this popover" signal (e.g. the checklist
    /// add-field activation token). A change clears the external-dismissal
    /// latch below, so a context-menu/palette request can always re-present
    /// even while the latch is waiting for the container to acknowledge an
    /// AppKit-side close.
    var presentationRequestToken: Int = 0
    /// Builds the popover body from the latest model; the second argument
    /// closes the popover (footer buttons, Return/Esc handling).
    let content: (Model, @escaping @MainActor () -> Void) -> PopoverContent

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    // NOTE: the coordinator's `isPresented` binding is REFRESHED on every
    // `updateNSView` (see below). The section builds that binding from its
    // per-render value snapshot, so a binding captured only at
    // `makeCoordinator` time reads a frozen value forever — a coordinator
    // created while the popover was hidden then saw `isPresented == false`
    // at `popoverDidClose` even when the container still said shown, skipped
    // the `false` write-back, and left the container state stuck `true`.
    // Every later model change then re-presented the popover with no user
    // action (the "popover opens while typing in the todo pane" bug).

    /// Anchor view for the popover. Retries a pending `present()` once it
    /// actually attaches to a window: a same-transaction "open immediately"
    /// request (e.g. a zero-item workspace's first Add Checklist Item, where
    /// the anchor is mounted in the very same SwiftUI update that also asks
    /// to present) can find `window == nil` on the first `present()` call,
    /// since AppKit view attachment can lag the SwiftUI commit that inserted
    /// it. Without this retry the request was silently dropped.
    final class AnchorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.anchorViewDidMoveToWindow()
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.coordinator = context.coordinator
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.minWidth = minWidth
        coordinator.maxHeight = maxHeight
        coordinator.preferredEdge = preferredEdge
        coordinator.isPresentedBinding = $isPresented
        coordinator.acknowledge(isPresented: isPresented, requestToken: presentationRequestToken)
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
        /// Refreshed by every `updateNSView` tick so reads and write-backs
        /// target the CURRENT container state, not the value snapshot from
        /// whichever render created this coordinator (see the note on
        /// `makeCoordinator`).
        var isPresentedBinding: Binding<Bool>
        private var isPresented: Bool {
            get { isPresentedBinding.wrappedValue }
            set { isPresentedBinding.wrappedValue = newValue }
        }
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
        /// Set when AppKit closed the popover out from under SwiftUI (app
        /// deactivation, transient click-away) while the container still said
        /// `isPresented == true`. The container's `isPresented = false` write
        /// lands asynchronously, so an unrelated re-render can deliver a
        /// stale `isPresented == true` to `updateNSView` first — without this
        /// latch that stale tick re-presents the popover the user just
        /// dismissed, producing a close/reopen churn loop (observed live:
        /// five `didShow`s in 18s with zero user actions). Cleared when the
        /// container acknowledges `false`, or when an explicit presentation
        /// request token changes.
        private var awaitingDismissAck = false
        private var lastRequestToken = 0

        init(isPresented: Binding<Bool>) {
            isPresentedBinding = isPresented
        }

        /// Called on every `updateNSView` tick, before `present()`/`dismiss()`.
        func acknowledge(isPresented: Bool, requestToken: Int) {
            if !isPresented {
                awaitingDismissAck = false
            }
            if requestToken != lastRequestToken {
                lastRequestToken = requestToken
                // Only a real request unlatches. Token zero is the CONSUMED
                // state (the container resets the activation token after the
                // add field arms) — treating that reset as a fresh request
                // re-presented a popover the user had just dismissed.
                if requestToken != 0 {
                    awaitingDismissAck = false
                }
            }
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

        /// Retries a pending open once the anchor finishes attaching to its
        /// window (see `AnchorView`). Without this, a `present()` call that
        /// hit a detached anchor had no way to recover except an unrelated
        /// later SwiftUI re-render happening to land after attachment.
        func anchorViewDidMoveToWindow() {
            guard isPresented, popover?.isShown != true else { return }
            present()
        }

        func present() {
            // After an AppKit-side close, wait for the container to confirm
            // the matching `isPresented = false` before honoring any further
            // present ticks — see `awaitingDismissAck`.
            guard !awaitingDismissAck else { return }
            guard let anchorView, let window = anchorView.window else {
                // No window yet — don't clobber isPresented. AnchorView's
                // viewDidMoveToWindow() retries once it actually attaches.
                return
            }
            let popover = popover ?? makePopover()
            // Everything below happens ONLY on the hidden-to-shown
            // transition: `present()` is re-entered on every parent update
            // tick while shown, and a window-wide layout flush (or an
            // identity bump) on those ticks would widen row-scoped checklist
            // churn into an app-wide synchronous layout pass per update.
            // While shown, content and size updates flow through
            // `update(model:builder:)` -> `refreshContent()` instead.
            guard !popover.isShown else { return }
            // Lay out from the window's root, not just the anchor's
            // immediate superview: `layoutSubtreeIfNeeded()` only resolves
            // the subtree it's called on, not ancestors above it. A
            // same-transaction "open immediately" anchor (a zero-item
            // workspace's first Add Checklist Item — see the AnchorView doc
            // comment) is freshly inserted into the sidebar's lazy list, so
            // the row containers above `anchorView.superview` may not have
            // an up-to-date frame yet. `popover.show(relativeTo:of:)`
            // resolves the anchor's window-coordinate position by walking
            // that whole ancestor chain, so a stale frame anywhere above the
            // immediate superview anchors the popover to the wrong spot.
            window.contentView?.layoutSubtreeIfNeeded()
            anchorView.superview?.layoutSubtreeIfNeeded()
            presentationCount += 1
            refreshContent()
            updateContentSize()
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
                // AppKit closed us (transient click-away / app deactivation)
                // while SwiftUI still thinks we're shown: latch until the
                // container acknowledges the write below, so stale re-render
                // ticks can't instantly re-present (churn loop).
                awaitingDismissAck = true
                isPresented = false
            }
#if DEBUG
            cmuxDebugLog("focus.todoPopover.didClose awaitingAck=\(awaitingDismissAck)")
#endif
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
