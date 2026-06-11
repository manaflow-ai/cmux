import AppKit
import CmuxSocketControl
import Bonsplit
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Sidebar drag auto-scroll
struct SidebarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> SidebarScrollViewResolverView {
        let view = SidebarScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SidebarScrollViewResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }
}

final class SidebarScrollViewResolverView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    func resolveScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onResolve?(self.enclosingScrollView)
        }
    }
}

enum SidebarAutoScrollDirection: Equatable {
    case up
    case down
}

struct SidebarAutoScrollPlan: Equatable {
    let direction: SidebarAutoScrollDirection
    let pointsPerTick: CGFloat
}

enum SidebarDragAutoScrollPlanner {
    static let edgeInset: CGFloat = 44
    static let minStep: CGFloat = 2
    static let maxStep: CGFloat = 12

    static func plan(
        distanceToTop: CGFloat,
        distanceToBottom: CGFloat,
        edgeInset: CGFloat = SidebarDragAutoScrollPlanner.edgeInset,
        minStep: CGFloat = SidebarDragAutoScrollPlanner.minStep,
        maxStep: CGFloat = SidebarDragAutoScrollPlanner.maxStep
    ) -> SidebarAutoScrollPlan? {
        guard edgeInset > 0, maxStep >= minStep else { return nil }
        if distanceToTop <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToTop) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .up, pointsPerTick: step)
        }
        if distanceToBottom <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToBottom) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .down, pointsPerTick: step)
        }
        return nil
    }
}

@MainActor
@Observable
final class SidebarDragAutoScrollController {
    weak var scrollView: NSScrollView?
    var timer: Timer?
    private var activePlan: SidebarAutoScrollPlan?

    func attach(scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    func updateFromDragLocation() {
        guard let scrollView else {
            stop()
            return
        }
        guard let plan = plan(for: scrollView) else {
            stop()
            return
        }
        activePlan = plan
        startTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activePlan = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons != 0 else {
            stop()
            return
        }
        guard let scrollView else {
            stop()
            return
        }

        // AppKit drag/drop autoscroll guidance recommends autoscroll(with:)
        // when periodic drag updates are available; use it first.
        if applyNativeAutoscroll(to: scrollView) {
            activePlan = plan(for: scrollView)
            if activePlan == nil {
                stop()
            }
            return
        }

        activePlan = self.plan(for: scrollView)
        guard let plan = activePlan else {
            stop()
            return
        }
        _ = apply(plan: plan, to: scrollView)
    }

    private func applyNativeAutoscroll(to scrollView: NSScrollView) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return false
        }

        let clipView = scrollView.contentView
        let didScroll = clipView.autoscroll(with: event)
        if didScroll {
            scrollView.reflectScrolledClipView(clipView)
        }
        return didScroll
    }

    private func distancesToEdges(mousePoint: CGPoint, viewportHeight: CGFloat, isFlipped: Bool) -> (top: CGFloat, bottom: CGFloat) {
        if isFlipped {
            return (top: mousePoint.y, bottom: viewportHeight - mousePoint.y)
        }
        return (top: viewportHeight - mousePoint.y, bottom: mousePoint.y)
    }

    private func planForMousePoint(_ mousePoint: CGPoint, in clipView: NSClipView) -> SidebarAutoScrollPlan? {
        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return nil }

        let distances = distancesToEdges(mousePoint: mousePoint, viewportHeight: viewportHeight, isFlipped: clipView.isFlipped)
        return SidebarDragAutoScrollPlanner.plan(distanceToTop: distances.top, distanceToBottom: distances.bottom)
    }

    private func mousePoint(in clipView: NSClipView) -> CGPoint {
        let mouseInWindow = clipView.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        return clipView.convert(mouseInWindow, from: nil)
    }

    private func currentPlan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        let clipView = scrollView.contentView
        let mouse = mousePoint(in: clipView)
        return planForMousePoint(mouse, in: clipView)
    }

    func plan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        currentPlan(for: scrollView)
    }

    func apply(plan: SidebarAutoScrollPlan, to scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView
        let maxOriginY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard maxOriginY > 0 else { return false }

        let directionMultiplier: CGFloat = (plan.direction == .down) ? 1 : -1
        let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
        let delta = directionMultiplier * flippedMultiplier * plan.pointsPerTick
        let currentY = clipView.bounds.origin.y
        let targetY = min(max(currentY + delta, 0), maxOriginY)
        guard abs(targetY - currentY) > 0.01 else { return false }

        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

