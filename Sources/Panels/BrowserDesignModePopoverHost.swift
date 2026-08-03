import AppKit
import CmuxBrowser
import Observation

/// Full-slot AppKit overlay for the Design Mode composer. Events outside the
/// floating card pass through to the page so element selection keeps working.
@MainActor
final class BrowserDesignModeComposerView: NSView {
    private static let edgeInset: CGFloat = 8

    private struct SelectionAnchor: Equatable {
        var selector: String
        var bounds: BrowserDesignModeRect
    }

    private struct State {
        var isPresented: Bool
        var selections: [BrowserDesignModeSelection]
        var resetGeneration: UInt
        var requestedChange: String
        var interactionMode: BrowserDesignModeInteractionMode
        var canCopy: Bool
        var didCopy: Bool
        var errorMessage: String?

        var activeAnchor: SelectionAnchor? {
            guard let selection = selections.last else { return nil }
            return SelectionAnchor(selector: selection.selector, bounds: selection.bounds)
        }
    }

    private let controller: BrowserDesignModeController
    private lazy var cardView = BrowserDesignModeCardView(controller: controller)
    private var cardOrigin: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var lastAnchor: SelectionAnchor?
    private var lastReportedCardFrame: CGRect = .zero
    private var trackingArea: NSTrackingArea?
    private var observationGeneration: UInt = 0

    var onPointerInsideCard: (() -> Void)?
    var onCardFrameChange: ((CGRect) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(controller: BrowserDesignModeController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        cardView.isHidden = true
        cardView.onPreferredHeightChange = { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        cardView.onPointerInside = { [weak self] in
            self?.onPointerInsideCard?()
        }
        cardView.onDrag = { [weak self] translation in
            self?.applyDrag(translation)
        }
        addSubview(cardView)
        observeController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if cardView.frame.contains(convert(event.locationInWindow, from: nil)) {
            onPointerInsideCard?()
        }
        super.mouseMoved(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !cardView.isHidden, cardView.frame.contains(convert(point, from: superview)) else {
            return nil
        }
        onPointerInsideCard?()
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !cardView.isHidden else { return }
        addCursorRect(cardView.frame, cursor: .arrow)
    }

    override func layout() {
        super.layout()
        guard !cardView.isHidden else { return }
        let size = cardView.intrinsicContentSize
        let origin: CGPoint
        if let cardOrigin {
            origin = clampedOrigin(cardOrigin, cardSize: size)
            self.cardOrigin = origin
        } else {
            origin = CGPoint(
                x: max(Self.edgeInset, (bounds.width - size.width) / 2),
                y: max(Self.edgeInset, bounds.height - size.height - 14)
            )
        }
        cardView.frame = CGRect(origin: origin, size: size)
        cardView.needsLayout = true
        reportCardFrameIfNeeded(cardView.frame)
    }

    private func observeController() {
        observationGeneration &+= 1
        let generation = observationGeneration
        let state = withObservationTracking {
            State(
                isPresented: controller.isComposerPresented,
                selections: controller.snapshot?.selections ?? [],
                resetGeneration: controller.promptResetGeneration,
                requestedChange: controller.requestedChange,
                interactionMode: controller.interactionMode,
                canCopy: controller.canCopy,
                didCopy: controller.didCopy,
                errorMessage: controller.errorMessage
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.observationGeneration == generation else { return }
                self.observeController()
            }
        }
        apply(state)
    }

    private func apply(_ state: State) {
        cardView.update(
            selections: state.selections,
            resetGeneration: state.resetGeneration,
            requestedChange: state.requestedChange,
            interactionMode: state.interactionMode,
            canCopy: state.canCopy,
            didCopy: state.didCopy,
            errorMessage: state.errorMessage
        )

        guard state.isPresented else {
            cardView.isHidden = true
            cardOrigin = nil
            dragStartOrigin = nil
            lastAnchor = nil
            reportCardFrameIfNeeded(.zero)
            return
        }

        let becameVisible = cardView.isHidden
        cardView.isHidden = false
        if state.activeAnchor != lastAnchor, dragStartOrigin == nil,
           let anchor = state.activeAnchor {
            cardOrigin = origin(near: anchor.bounds, cardSize: cardView.intrinsicContentSize)
        }
        lastAnchor = state.activeAnchor
        needsLayout = true
        layoutSubtreeIfNeeded()
        if becameVisible {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.cardView.focusEditor()
            }
        }
    }

    private func applyDrag(_ translation: CGSize?) {
        guard let translation else {
            dragStartOrigin = nil
            return
        }
        let start = dragStartOrigin ?? cardView.frame.origin
        dragStartOrigin = start
        cardOrigin = clampedOrigin(
            CGPoint(x: start.x + translation.width, y: start.y + translation.height),
            cardSize: cardView.intrinsicContentSize
        )
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func origin(near target: BrowserDesignModeRect, cardSize: CGSize) -> CGPoint {
        let gap: CGFloat = 10
        var x = CGFloat(target.x + target.width / 2) - cardSize.width / 2
        var y = CGFloat(target.y + target.height) + gap
        if y + cardSize.height > bounds.height - Self.edgeInset {
            y = CGFloat(target.y) - cardSize.height - gap
        }
        x = min(max(x, Self.edgeInset), max(Self.edgeInset, bounds.width - cardSize.width - Self.edgeInset))
        y = min(max(y, Self.edgeInset), max(Self.edgeInset, bounds.height - cardSize.height - Self.edgeInset))
        return CGPoint(x: x, y: y)
    }

    private func clampedOrigin(_ proposed: CGPoint, cardSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(proposed.x, Self.edgeInset), max(Self.edgeInset, bounds.width - cardSize.width - Self.edgeInset)),
            y: min(max(proposed.y, Self.edgeInset), max(Self.edgeInset, bounds.height - cardSize.height - Self.edgeInset))
        )
    }

    private func reportCardFrameIfNeeded(_ frame: CGRect) {
        guard frame != lastReportedCardFrame else { return }
        lastReportedCardFrame = frame
        onCardFrameChange?(frame)
    }
}
