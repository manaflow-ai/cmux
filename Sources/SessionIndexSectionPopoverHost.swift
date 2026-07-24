import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Hosts SectionPopoverView in a real NSPopover. SwiftUI's native `.popover()`
/// doesn't reliably let the embedded TextField become first responder in cmux's
/// focus-managed environment because the terminal keeps grabbing focus back.
struct SectionPopoverHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let section: IndexSection
    /// Closure-typed search handle passed through to the SwiftUI popover
    /// body. The host no longer holds a `SessionIndexStore` reference.
    let search: SessionSearchFn
    let loadSnapshot: DirectorySnapshotFn
    let onResume: ((SessionEntry) -> Void)?

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
        coordinator.update(
            section: section,
            search: search,
            loadSnapshot: loadSnapshot,
            onResume: onResume
        )
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
        private(set) var refreshContentCallCount = 0
        var isPopoverShown: Bool { popover?.isShown == true }

        private let hostingController: NSHostingController<AnyView> = {
            NSHostingController(rootView: AnyView(EmptyView()))
            // DO NOT set sizingOptions here. It makes NSHostingController
            // continuously rewrite preferredContentSize from SwiftUI layout,
            // which lets NSPopover override our manual contentSize and latch
            // onto a partial first-pass height.
        }()
        private var popover: NSPopover?
        private var currentSection: IndexSection?
        private var currentSearch: SessionSearchFn?
        private var currentLoadSnapshot: DirectorySnapshotFn?
        private var currentOnResume: ((SessionEntry) -> Void)?
        private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
        private var lastRenderedSection: IndexSection?
        private var lastRenderedPresentationCount: Int?
        /// Bumped on every present(). Used as the SwiftUI view identity so each
        /// open gets fresh view-local state.
        private var presentationCount = 0

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func update(
            section: IndexSection,
            search: @escaping SessionSearchFn,
            loadSnapshot: @escaping DirectorySnapshotFn,
            onResume: ((SessionEntry) -> Void)?
        ) {
            currentSection = section
            currentSearch = search
            currentLoadSnapshot = loadSnapshot
            currentOnResume = onResume
            // When hidden, defer rebuilding the hosting view until `present()`.
            // Rewriting rootView + forcing layout on every parent re-render was
            // the 100% CPU loop behind https://github.com/manaflow-ai/cmux/issues/3010.
            guard popover?.isShown == true else { return }
            guard lastRenderedSection != section || lastRenderedPresentationCount != presentationCount else { return }
            scheduleVisibleRefresh()
        }

        private func scheduleVisibleRefresh() {
            visibleUpdateScheduler.schedule { [weak self] in
                guard let self, self.popover?.isShown == true else { return }
                self.refreshContent()
            }
        }

        private func refreshContent() {
            guard let section = currentSection,
                  let search = currentSearch,
                  let loadSnapshot = currentLoadSnapshot else { return }
            refreshContentCallCount += 1
            let onResume = currentOnResume
            let identity = presentationCount
            hostingController.rootView = AnyView(
                SectionPopoverView(
                    section: section,
                    search: search,
                    loadSnapshot: loadSnapshot,
                    onResume: onResume
                ) { [weak self] in
                    self?.closeFromContent()
                }
                // Tied to presentationCount so reopening the popover discards
                // the prior open's view-local search and scroll state.
                .id(identity)
            )
            lastRenderedSection = section
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
            if !popover.isShown {
                visibleUpdateScheduler.cancel()
                presentationCount += 1
                refreshContent()
            }
            updateContentSize()
            guard !popover.isShown else { return }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        }

        func dismiss() {
            visibleUpdateScheduler.cancel()
            popover?.performClose(nil)
        }

        func closeFromContent() {
            isPresented = false
            dismiss()
        }

        func popoverDidClose(_ notification: Notification) {
            visibleUpdateScheduler.cancel()
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
            guard let popover else { return }
            CmuxPopoverMutation.setContentSize(NSSize(
                width: ceil(max(fitting.width, 360)),
                height: ceil(min(fitting.height, 480))
            ), on: popover)
        }
    }
}
