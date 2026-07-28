import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Owns the AppKit popover lifecycle for one transcript preview host.
@MainActor
final class SessionTranscriptPopoverCoordinator: NSObject, NSPopoverDelegate {
    @Binding var isPresented: Bool
    weak var anchorView: NSView?

    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
    private var popover: NSPopover?
    private var currentEntry: SessionEntry?
    private let sizeModel = SessionTranscriptPopoverSizeModel()
    private var wantsPresentation = false

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    func update(entry: SessionEntry) {
        let shouldRefresh = currentEntry?.id != entry.id
        currentEntry = entry
        if shouldRefresh {
            if popover?.isShown == true {
                scheduleVisibleRefresh()
            } else {
                refreshContent()
            }
        }
    }

    private func scheduleVisibleRefresh() {
        visibleUpdateScheduler.schedule { [weak self] in
            guard let self, self.popover?.isShown == true else { return }
            self.refreshContent()
        }
    }

    func anchorDidMoveToWindow() {
        guard anchorView?.window != nil else {
            popover?.performClose(nil)
            return
        }
        if wantsPresentation {
            present()
        }
    }

    func present() {
        wantsPresentation = true
        guard let anchorView, anchorView.window != nil else {
            return
        }
        anchorView.superview?.layoutSubtreeIfNeeded()
        let popover = popover ?? makePopover()
        if !popover.isShown {
            visibleUpdateScheduler.cancel()
            refreshContent()
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        }
    }

    func dismiss() {
        wantsPresentation = false
        visibleUpdateScheduler.cancel()
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        visibleUpdateScheduler.cancel()
        wantsPresentation = false
        popover = nil
        if isPresented {
            isPresented = false
        }
    }

    private func refreshContent() {
        guard let entry = currentEntry else { return }
        hostingController.rootView = AnyView(
            SessionTranscriptPreviewView(
                entry: entry,
                sizeModel: sizeModel,
                onResize: { [weak self] proposedSize in
                    self?.resize(to: proposedSize)
                }
            ) { [weak self] in
                self?.closeFromContent()
            }
            .id(entry.id)
        )
        hostingController.view.invalidateIntrinsicContentSize()
        hostingController.view.layoutSubtreeIfNeeded()
        updatePopoverSize()
    }

    private func closeFromContent() {
        isPresented = false
        dismiss()
    }

    private func resize(to proposedSize: CGSize) {
        sizeModel.size = SessionTranscriptPreviewLayout.clamped(proposedSize)
        updatePopoverSize()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: sizeModel.size.width, height: sizeModel.size.height)
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func updatePopoverSize() {
        guard let popover else { return }
        CmuxPopoverMutation.setContentSize(
            NSSize(width: sizeModel.size.width, height: sizeModel.size.height),
            on: popover
        )
    }
}
