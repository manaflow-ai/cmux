import AppKit
import CmuxAppKitSupportUI
import Combine
import QuartzCore
import SwiftUI

/// Native divider tracking for the sidebar resizers.
///
/// Runs the same synchronous mouse-tracking loop NSSplitView uses: from
/// mouseDown, events are pulled with `nextEvent(matching:)` until mouse-up,
/// and after each width update the runloop sleeps briefly in `.eventTracking`
/// mode so SwiftUI/Core Animation commit the new layout inside the loop,
/// then the window presents. The divider therefore stays glued to the
/// cursor with no async runloop hop, while the panes remain SwiftUI-owned
/// (both blend modes keep their existing geometry).
struct SidebarDividerTracker: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> SidebarDividerTrackingView {
        let view = SidebarDividerTrackingView()
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: SidebarDividerTrackingView, context: Context) {
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}

/// Bridges the existing SwiftUI sidebar and content trees into the AppKit
/// container that authoritatively owns their horizontal geometry.
struct SidebarContentLayoutHost: NSViewRepresentable {
    let sidebarRoot: AnyView
    let mainContentRoot: AnyView
    let layout: SidebarLayoutModel
    let isSidebarVisible: Bool
    let mode: SidebarContentLayoutMode
    let onDividerBegan: (CGFloat) -> Void
    let onDividerChanged: (CGFloat, CGFloat) -> Void
    let onDividerEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sidebarRoot: sidebarRoot,
            mainContentRoot: mainContentRoot,
            layout: layout
        )
    }

    func makeNSView(context: Context) -> SidebarContentLayoutView {
        let divider = SidebarDividerTrackingView()
        divider.identifier = NSUserInterfaceItemIdentifier("SidebarResizer")
        divider.setAccessibilityElement(true)
        divider.setAccessibilityRole(.splitter)
        divider.setAccessibilityIdentifier("SidebarResizer")

        let container = SidebarContentLayoutView(
            sidebarView: context.coordinator.sidebarHostingView,
            mainContentView: context.coordinator.mainContentHostingView,
            dividerView: divider,
            configuration: configuration(width: layout.width)
        )
        context.coordinator.attach(container: container, divider: divider)
        context.coordinator.update(from: self)
        return container
    }

    func updateNSView(_ nsView: SidebarContentLayoutView, context: Context) {
        context.coordinator.update(from: self)
    }

    private func configuration(width: CGFloat) -> SidebarContentLayoutConfiguration {
        SidebarContentLayoutConfiguration(
            sidebarWidth: width,
            isSidebarVisible: isSidebarVisible,
            mode: mode,
            dividerLeadingHitWidth: SidebarResizeInteraction.sidebarSideHitWidth,
            dividerTrailingHitWidth: SidebarResizeInteraction.contentSideHitWidth
        )
    }

    @MainActor
    final class Coordinator {
        let sidebarHostingView: NSHostingView<AnyView>
        let mainContentHostingView: NSHostingView<AnyView>

        private weak var container: SidebarContentLayoutView?
        private weak var divider: SidebarDividerTrackingView?
        private var widthObservation: AnyCancellable?
        private var observedLayout: SidebarLayoutModel
        private var latestWidth: CGFloat
        private var isSidebarVisible = true
        private var mode = SidebarContentLayoutMode.sideBySide
        private var isDividerTracking = false
        private var onDividerBegan: (CGFloat) -> Void = { _ in }
        private var onDividerChanged: (CGFloat, CGFloat) -> Void = { _, _ in }
        private var onDividerEnded: (CGFloat) -> Void = { _ in }

        init(
            sidebarRoot: AnyView,
            mainContentRoot: AnyView,
            layout: SidebarLayoutModel
        ) {
            sidebarHostingView = NSHostingView(rootView: sidebarRoot)
            mainContentHostingView = NSHostingView(rootView: mainContentRoot)
            observedLayout = layout
            latestWidth = layout.width

            // The AppKit container dictates both host sizes. Opt out of
            // NSHostingView's intrinsic-size negotiation so its ideal SwiftUI
            // size cannot feed back into the split geometry.
            sidebarHostingView.sizingOptions = []
            mainContentHostingView.sizingOptions = []
        }

        func attach(
            container: SidebarContentLayoutView,
            divider: SidebarDividerTrackingView
        ) {
            self.container = container
            self.divider = divider
            bindDividerCallbacks()
            observeWidth(of: observedLayout)
        }

        func update(from host: SidebarContentLayoutHost) {
            sidebarHostingView.rootView = host.sidebarRoot
            mainContentHostingView.rootView = host.mainContentRoot
            isSidebarVisible = host.isSidebarVisible
            mode = host.mode
            onDividerBegan = host.onDividerBegan
            onDividerChanged = host.onDividerChanged
            onDividerEnded = host.onDividerEnded

            if observedLayout !== host.layout {
                observedLayout = host.layout
                latestWidth = host.layout.width
                observeWidth(of: host.layout)
            }

            applyCurrentConfiguration(synchronously: false)
            bindDividerCallbacks()
        }

        private func observeWidth(of layout: SidebarLayoutModel) {
            widthObservation = layout.$width
                .removeDuplicates()
                .sink { [weak self] width in
                    guard let self else { return }
                    latestWidth = width
                    applyCurrentConfiguration(synchronously: isDividerTracking)
                }
        }

        private func bindDividerCallbacks() {
            divider?.onBegan = { [weak self] in
                guard let self else { return }
                isDividerTracking = true
                onDividerBegan(availableWidth)
            }
            divider?.onChanged = { [weak self] translation in
                guard let self else { return }
                onDividerChanged(translation, availableWidth)
            }
            divider?.onEnded = { [weak self] in
                guard let self else { return }
                onDividerEnded(availableWidth)
                isDividerTracking = false
            }
        }

        private var availableWidth: CGFloat {
            max(0, container?.bounds.width ?? 0)
        }

        private func applyCurrentConfiguration(synchronously: Bool) {
            container?.apply(
                configuration: SidebarContentLayoutConfiguration(
                    sidebarWidth: latestWidth,
                    isSidebarVisible: isSidebarVisible,
                    mode: mode,
                    dividerLeadingHitWidth: SidebarResizeInteraction.sidebarSideHitWidth,
                    dividerTrailingHitWidth: SidebarResizeInteraction.contentSideHitWidth
                ),
                synchronously: synchronously
            )
        }
    }
}

@MainActor
final class SidebarDividerTrackingView: NSView {
    var onBegan: (() -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?

#if DEBUG
    // Routing diagnosis: sidebar-resize bugs have historically been fights
    // over who wins pointer hit-testing (portal vs SwiftUI vs this view).
    // Log the winning view class for each left mouse-down so a stolen drag
    // is attributable from the debug log alone.
    private static var diagnosticsInstalled = false
    private static func installDiagnosticsIfNeeded() {
        guard !diagnosticsInstalled else { return }
        diagnosticsInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if let contentView = event.window?.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                let hit = contentView.hitTest(point)
                cmuxDebugLog(
                    "sidebar.divider.downRouting x=\(Int(event.locationInWindow.x)) " +
                    "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
                )
            }
            return event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.installDiagnosticsIfNeeded() }
    }
#endif

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    // Divider drags work without first activating the window, matching
    // NSSplitView.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onBegan?()
        let startX = event.locationInWindow.x
        var eventCount = 0
        var writeMs = 0.0, commitMs = 0.0, layoutMs = 0.0, displayMs = 0.0, flushMs = 0.0
        NSCursor.resizeLeftRight.push()
        let startedAt = CACurrentMediaTime()
        defer {
            NSCursor.pop()
            onEnded?()
#if DEBUG
            let fmt = { (v: Double) in String(format: "%.0f", v * 1000) }
            cmuxDebugLog(
                "sidebar.divider.drag events=\(eventCount) " +
                "duration=\(fmt(CACurrentMediaTime() - startedAt))ms " +
                "write=\(fmt(writeMs)) commit=\(fmt(commitMs)) layout=\(fmt(layoutMs)) " +
                "display=\(fmt(displayMs)) caFlush=\(fmt(flushMs))"
            )
#endif
        }
        while true {
            guard var next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            // Track the newest queued position: high-polling mice deliver
            // drags faster than frames present, and replaying stale ones
            // would put the divider behind the cursor.
            while next.type == .leftMouseDragged,
                  let queued = window.nextEvent(
                      matching: [.leftMouseDragged, .leftMouseUp],
                      until: Date(),
                      inMode: .eventTracking,
                      dequeue: true
                  ) {
                next = queued
            }
            if next.type == .leftMouseUp {
                break
            }
            eventCount += 1
            let t0 = CACurrentMediaTime()
            onChanged?(next.locationInWindow.x - startX)
            let t1 = CACurrentMediaTime()
            // A zero-deadline runloop pass returns before the before-waiting
            // phase, which is where SwiftUI and Core Animation register their
            // commit observers — so the width write would present a frame (or
            // more) late. A real 1ms deadline lets the loop reach that phase
            // and commit inside this event; then present.
            RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.001))
            let t2 = CACurrentMediaTime()
            window.contentView?.layoutSubtreeIfNeeded()
            let t3 = CACurrentMediaTime()
            window.displayIfNeeded()
            let t4 = CACurrentMediaTime()
            CATransaction.flush()
            let t5 = CACurrentMediaTime()
            writeMs += t1 - t0
            commitMs += t2 - t1
            layoutMs += t3 - t2
            displayMs += t4 - t3
            flushMs += t5 - t4
        }
    }
}
