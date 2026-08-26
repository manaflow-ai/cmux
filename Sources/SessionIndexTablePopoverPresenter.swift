import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Owns the single Vault popover outside recycled SwiftUI row graphs.
///
/// A row state change can arrive while AppKit is laying out its table. Keeping
/// the popover here lets the table finish its staged apply before hosted
/// popover content is replaced or measured, and keeps representable updates
/// out of that AppKit layout stack entirely.
@MainActor
final class SessionIndexTablePopoverPresenter: NSObject, NSPopoverDelegate {
    private lazy var hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
    private let transcriptLayout: SessionTranscriptPopoverLayout
    private let transcriptSizeModel: SessionTranscriptPopoverSizeModel
    private var popover: NSPopover?
    private var currentPresentation: SessionIndexTablePopoverPresentation?
    private var pendingPresentation: (
        presentation: SessionIndexTablePopoverPresentation,
        anchorView: NSView,
        anchorRect: NSRect
    )?
    private weak var anchorView: NSView?
    private var presentationCount = 0
    private var isClosingProgrammatically = false

    var isPopoverShown: Bool { popover?.isShown == true }

    init(transcriptLayout: SessionTranscriptPopoverLayout = SessionTranscriptPopoverLayout()) {
        self.transcriptLayout = transcriptLayout
        transcriptSizeModel = SessionTranscriptPopoverSizeModel(size: transcriptLayout.defaultSize)
        super.init()
    }

    func reconcile(
        _ presentation: SessionIndexTablePopoverPresentation,
        relativeTo anchorRect: NSRect,
        of anchorView: NSView
    ) {
        guard anchorView.window != nil else { return }

        if isPopoverShown,
           currentPresentation?.identity == presentation.identity,
           self.anchorView === anchorView {
            let needsRefresh = currentPresentation?.hasEquivalentContent(to: presentation) != true
            currentPresentation = presentation
            if needsRefresh {
                scheduleVisibleRefresh()
            }
            return
        }

        pendingPresentation = (
            presentation: presentation,
            anchorView: anchorView,
            anchorRect: anchorRect
        )

        if isPopoverShown || isClosingProgrammatically {
            closeForReplacementIfNeeded()
        } else {
            presentPendingPresentation()
        }
    }

    func dismiss() {
        pendingPresentation = nil
        visibleUpdateScheduler.cancel()
        guard let popover, popover.isShown else {
            resetPresentedContent()
            return
        }
        isClosingProgrammatically = true
        popover.performClose(nil)
    }

    func dismissAndNotify() {
        let onDismiss = currentPresentation?.onDismiss
            ?? pendingPresentation?.presentation.onDismiss
        dismiss()
        onDismiss?()
    }

    func isAnchored(in view: NSView) -> Bool {
        guard let anchorView else { return false }
        return anchorView === view || anchorView.isDescendant(of: view)
    }

    private func closeForReplacementIfNeeded() {
        guard !isClosingProgrammatically else { return }
        guard let popover, popover.isShown else {
            resetPresentedContent()
            presentPendingPresentation()
            return
        }
        visibleUpdateScheduler.cancel()
        isClosingProgrammatically = true
        popover.performClose(nil)
    }

    private func presentPendingPresentation() {
        guard let pendingPresentation else { return }
        self.pendingPresentation = nil
        guard pendingPresentation.anchorView.window != nil else {
            pendingPresentation.presentation.onDismiss()
            return
        }

        currentPresentation = pendingPresentation.presentation
        anchorView = pendingPresentation.anchorView
        presentationCount += 1
        visibleUpdateScheduler.cancel()

        let popover = makePopover()
        refreshContent()
        popover.show(
            relativeTo: pendingPresentation.anchorRect,
            of: pendingPresentation.anchorView,
            preferredEdge: .maxX
        )
    }

    private func scheduleVisibleRefresh() {
        visibleUpdateScheduler.schedule { [weak self] in
            guard let self, self.isPopoverShown else { return }
            self.refreshContent()
        }
    }

    private func refreshContent() {
        guard let currentPresentation else { return }

        switch currentPresentation.content {
        case let .section(section, search, loadSnapshot, beginSessionDrag, onResume):
            hostingController.rootView = AnyView(
                SectionPopoverView(
                    section: section,
                    search: search,
                    loadSnapshot: loadSnapshot,
                    beginSessionDrag: beginSessionDrag,
                    onResume: onResume
                ) { [weak self] in
                    self?.dismissAndNotify()
                }
                .id(presentationCount)
            )
        case .transcript(let entry):
            hostingController.rootView = AnyView(
                SessionTranscriptPreviewView(
                    entry: entry,
                    sizeModel: transcriptSizeModel,
                    onResize: { [weak self] proposedSize in
                        self?.resizeTranscript(to: proposedSize)
                    }
                ) { [weak self] in
                    self?.dismissAndNotify()
                }
                .id(presentationCount)
            )
        }

        hostingController.view.invalidateIntrinsicContentSize()
        hostingController.view.layoutSubtreeIfNeeded()
        updateContentSize()
    }

    private func resizeTranscript(to proposedSize: CGSize) {
        transcriptSizeModel.size = transcriptLayout.clamped(proposedSize)
        updateContentSize()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func updateContentSize() {
        guard let popover, let currentPresentation else { return }
        let size: NSSize
        switch currentPresentation.content {
        case .section:
            let fitting = hostingController.view.fittingSize
            guard fitting.width > 0, fitting.height > 0 else { return }
            size = NSSize(
                width: ceil(max(fitting.width, 360)),
                height: ceil(min(fitting.height, 480))
            )
        case .transcript:
            size = NSSize(
                width: transcriptSizeModel.size.width,
                height: transcriptSizeModel.size.height
            )
        }
        CmuxPopoverMutation.setContentSize(size, on: popover)
    }

    private func resetPresentedContent() {
        visibleUpdateScheduler.cancel()
        popover = nil
        currentPresentation = nil
        anchorView = nil
        hostingController.rootView = AnyView(EmptyView())
    }

    func popoverDidClose(_ notification: Notification) {
        let shouldNotify = !isClosingProgrammatically
        let onDismiss = currentPresentation?.onDismiss
        isClosingProgrammatically = false
        resetPresentedContent()

        if pendingPresentation != nil {
            presentPendingPresentation()
        } else if shouldNotify {
            onDismiss?()
        }
    }
}

extension SessionIndexTableRow {
    var popoverPresentation: SessionIndexTablePopoverPresentation? {
        guard case let .section(
            section,
            _,
            _,
            popoverIdentity,
            _,
            actions,
            _,
            setPopoverOpen
        ) = self,
        let popoverIdentity,
        popoverIdentity.sectionKey == section.key else {
            return nil
        }

        switch popoverIdentity {
        case .transcript(_, let entryID):
            guard let entryID = Self.containedPreviewEntryID(entryID, in: section),
                  let entry = section.entries.first(where: { $0.id == entryID }) else {
                return nil
            }
            return SessionIndexTablePopoverPresentation(
                identity: .transcript(section: section.key, entry: entry.id),
                content: .transcript(entry),
                onDismiss: { actions.onDismissPreview(entry.id) }
            )
        case .section:
            return SessionIndexTablePopoverPresentation(
                identity: .section(section.key),
                content: .section(
                    section: section,
                    search: actions.search,
                    loadSnapshot: actions.loadSnapshot,
                    beginSessionDrag: actions.beginSessionDrag,
                    onResume: actions.onResume
                ),
                onDismiss: { setPopoverOpen(false) }
            )
        }
    }
}
