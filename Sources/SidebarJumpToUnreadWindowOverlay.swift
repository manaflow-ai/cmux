import AppKit
import Combine
import SwiftUI

extension SidebarJumpToUnreadButton {
    /// One per window: a hosting view in the portal's overlay container, right
    /// above every terminal and browser host (later overlays such as the
    /// command palette stay above it), covering a fixed band at the bottom
    /// center of the window content. SwiftUI lays the capsule out inside that
    /// band, so it can grow on hover and animate freely; the host only takes
    /// clicks and sets the cursor inside the capsule, everything else passes
    /// through to the terminal.
    @MainActor
    final class WindowOverlay {
        private static var associationKey: UInt8 = 0
        /// The band the capsule lives in: wide enough for the confirm text,
        /// tall enough for the capsule plus its shadow.
        private static let bandSize = CGSize(width: 560, height: 56)
        /// Capsule bottom edge to window content bottom.
        private static let bottomInset: CGFloat = 16
        /// Band bottom to capsule bottom, leaving room for the shadow.
        private static let shadowRoom: CGFloat = 10

        static func controller(for window: NSWindow) -> WindowOverlay {
            if let existing = objc_getAssociatedObject(window, &associationKey) as? WindowOverlay { return existing }
            let created = WindowOverlay(window: window)
            objc_setAssociatedObject(window, &associationKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return created
        }

        private weak var window: NSWindow?
        private let chromeComposition = AppWindowChromeComposition()
        private var host: Host?
        private var unreadSubscription: AnyCancellable?
        private weak var observedReference: NSView?
        private var referenceObserver: NSObjectProtocol?

        private init(window: NSWindow) {
            self.window = window
        }

        deinit { if let referenceObserver { NotificationCenter.default.removeObserver(referenceObserver) } }

        func show(_ content: SidebarJumpToUnreadButton) {
            let rootView = AnyView(
                content
                    .fixedSize()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CapsuleFrameKey.self, value: proxy.frame(in: .named(Self.space)))
                    })
                    .padding(.bottom, Self.shadowRoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .coordinateSpace(name: Self.space)
                    .onPreferenceChange(CapsuleFrameKey.self) { [weak self] rect in
                        MainActor.assumeIsolated { self?.host?.capsuleRect = rect }
                    }
                    .cmuxAccentColorEnvironment()
                    .cmuxFontMagnificationEnvironment()
            )
            if let host {
                host.rootView = rootView
            } else {
                let host = Host(rootView: rootView)
                host.sizingOptions = []
                self.host = host
            }
            // A new count re-promotes, in case a portal host was re-added above.
            unreadSubscription = unreadSubscription ?? TerminalNotificationStore.shared.$notificationMenuSnapshot
                .map(\.unreadCount)
                .removeDuplicates()
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }
            layout()
        }

        func remove() {
            unreadSubscription = nil
            host?.removeFromSuperview()
            host = nil
            observeReference(nil)
        }

        private static let space = "SidebarJumpToUnreadWindowOverlay"

        private func layout() {
            guard let window, let host,
                  let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window)
            else { host?.removeFromSuperview(); return }
            let container = target.container
            promoteAbovePortals(host, in: container, reference: target.reference)
            observeReference(target.reference)
            let area = container.convert(target.reference.bounds, from: target.reference)
            let width = min(Self.bandSize.width, max(0, area.width - 24))
            let height = Self.bandSize.height
            let bottom = Self.bottomInset - Self.shadowRoom
            let frame = NSRect(
                x: (area.midX - width / 2).rounded(),
                y: container.isFlipped ? area.maxY - bottom - height : area.minY + bottom,
                width: width, height: height
            )
            if host.frame != frame { host.frame = frame }
        }

        /// Portal hosts install just above the content view and can be
        /// re-added as splits and workspaces change; stay above the topmost.
        private func promoteAbovePortals(_ view: NSView, in container: NSView, reference: NSView) {
            let siblings = container.subviews
            let portal = siblings.last { $0 is WindowTerminalHostView || $0 is WindowBrowserHostView }
                ?? (reference.superview === container ? reference : nil)
            let portalIndex = portal.flatMap { candidate in siblings.firstIndex { $0 === candidate } } ?? -1
            if let index = siblings.firstIndex(where: { $0 === view }), index > portalIndex { return }
            container.addSubview(view, positioned: .above, relativeTo: portal)
        }

        private func observeReference(_ reference: NSView?) {
            guard observedReference !== reference else { return }
            if let referenceObserver { NotificationCenter.default.removeObserver(referenceObserver) }
            referenceObserver = nil
            observedReference = reference
            guard let reference else { return }
            reference.postsFrameChangedNotifications = true
            referenceObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: reference, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            }
        }

        /// Never takes keyboard focus (the terminal stays first responder),
        /// takes the first click in an inactive window, and only claims the
        /// capsule: clicks and the cursor elsewhere in the band go to the
        /// terminal beneath, and over the capsule the cursor is an arrow.
        private final class Host: NSHostingView<AnyView> {
            /// The capsule, in SwiftUI's top-left coordinates of this view.
            var capsuleRect: CGRect = .zero {
                didSet { if capsuleRect != oldValue { window?.invalidateCursorRects(for: self) } }
            }

            override var acceptsFirstResponder: Bool { false }
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

            private var capsuleInBounds: NSRect {
                isFlipped ? capsuleRect : NSRect(
                    x: capsuleRect.minX, y: bounds.height - capsuleRect.maxY,
                    width: capsuleRect.width, height: capsuleRect.height
                )
            }

            override func hitTest(_ point: NSPoint) -> NSView? {
                let local = convert(point, from: superview)
                guard capsuleInBounds.contains(local) else { return nil }
                return super.hitTest(point)
            }

            override func resetCursorRects() {
                addCursorRect(capsuleInBounds, cursor: .arrow)
            }
        }

        private struct CapsuleFrameKey: PreferenceKey {
            static let defaultValue: CGRect = .zero
            static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
        }
    }
}
