import AppKit
import CmuxAppKitSupportUI
import SwiftUI

enum SessionIndexTablePopoverIdentity: Equatable {
    case section(SectionKey)
    case transcript(section: SectionKey, entry: SessionEntry.ID)

    var sectionKey: SectionKey {
        switch self {
        case .section(let key), .transcript(let key, _):
            return key
        }
    }
}

struct SessionIndexTablePopoverPresentation {
    enum Content {
        case section(
            section: IndexSection,
            search: SessionSearchFn,
            loadSnapshot: DirectorySnapshotFn,
            onResume: ((SessionEntry) -> Void)?
        )
        case transcript(SessionEntry)
    }

    let identity: SessionIndexTablePopoverIdentity
    let content: Content
    let onDismiss: @MainActor () -> Void

    func hasEquivalentContent(to other: Self) -> Bool {
        switch (content, other.content) {
        case let (.section(lhs, _, _, _), .section(rhs, _, _, _)):
            return lhs == rhs
        case let (.transcript(lhs), .transcript(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

/// Owns the single Vault popover outside recycled SwiftUI row graphs.
///
/// A row state change can arrive while AppKit is laying out its table. Keeping
/// the popover here lets the table finish its staged apply before hosted
/// popover content is replaced or measured, and keeps representable updates
/// out of that AppKit layout stack entirely.
@MainActor
final class SessionIndexTablePopoverPresenter: NSObject, NSPopoverDelegate {
    private struct PendingPresentation {
        let presentation: SessionIndexTablePopoverPresentation
        let anchorView: NSView
        let anchorRect: NSRect
    }

    private lazy var hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
    private let transcriptSizeModel = SessionTranscriptPopoverSizeModel()
    private var popover: NSPopover?
    private var currentPresentation: SessionIndexTablePopoverPresentation?
    private var pendingPresentation: PendingPresentation?
    private weak var anchorView: NSView?
    private var presentationCount = 0
    private var isClosingProgrammatically = false

    private(set) var refreshContentCallCount = 0
    var isPopoverShown: Bool { popover?.isShown == true }
    var presentedIdentity: SessionIndexTablePopoverIdentity? { currentPresentation?.identity }

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

        pendingPresentation = PendingPresentation(
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
        refreshContentCallCount += 1

        switch currentPresentation.content {
        case let .section(section, search, loadSnapshot, onResume):
            hostingController.rootView = AnyView(
                SectionPopoverView(
                    section: section,
                    search: search,
                    loadSnapshot: loadSnapshot,
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
        transcriptSizeModel.size = SessionTranscriptPreviewLayout.clamped(proposedSize)
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
            previewEntryId,
            _,
            isPopoverOpen,
            actions,
            _,
            setPopoverOpen
        ) = self else {
            return nil
        }

        if let previewEntryId = Self.containedPreviewEntryID(previewEntryId, in: section),
           let entry = section.entries.first(where: { $0.id == previewEntryId }) {
            return SessionIndexTablePopoverPresentation(
                identity: .transcript(section: section.key, entry: entry.id),
                content: .transcript(entry),
                onDismiss: { actions.onDismissPreview(entry.id) }
            )
        }

        guard isPopoverOpen else { return nil }
        return SessionIndexTablePopoverPresentation(
            identity: .section(section.key),
            content: .section(
                section: section,
                search: actions.search,
                loadSnapshot: actions.loadSnapshot,
                onResume: actions.onResume
            ),
            onDismiss: { setPopoverOpen(false) }
        )
    }
}
