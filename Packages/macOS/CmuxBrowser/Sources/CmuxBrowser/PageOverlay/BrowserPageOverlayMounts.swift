public import SwiftUI

extension View {
    /// Marks this view as an occluding page overlay (a bar or card that takes
    /// the keyboard: find bar, permission bar, crash page). Over a Chromium
    /// page the page leaves a hole where it shows; over a WebKit page, or
    /// with a nil coordinator, nothing changes.
    public func browserPageOccluding(_ coordinator: BrowserPageOverlayCoordinator?, id: String) -> some View {
        background(BrowserPageOverlayAnchor(coordinator: coordinator, id: id, floatingContent: nil))
    }
}

/// A floating page overlay (a rounded card over the live page, such as the
/// engine notice). Over a Chromium page it draws in a non-activating child
/// panel above the page, sized and placed where it would lay out here; over
/// a WebKit page it renders in place.
///
/// In a panel the content gets its own hosting view: it takes the window's
/// appearance, not this view's SwiftUI environment, so pass anything it
/// reads (colors, fonts, models) explicitly.
public struct BrowserPageFloatingOverlay<Content: View>: View {
    @ObservedObject private var coordinator: BrowserPageOverlayCoordinator
    private let id: String
    private let content: Content

    public init(coordinator: BrowserPageOverlayCoordinator, id: String, @ViewBuilder content: () -> Content) {
        self.coordinator = coordinator
        self.id = id
        self.content = content()
    }

    public var body: some View {
        if coordinator.hostsFloatingOverlaysInPanels {
            // Lays out here (hidden) so the panel gets the same frame.
            content
                .hidden()
                .background(BrowserPageOverlayAnchor(coordinator: coordinator, id: id, floatingContent: AnyView(content)))
        } else {
            content
        }
    }
}

/// The invisible view that reports an overlay's frame to the coordinator.
struct BrowserPageOverlayAnchor: NSViewRepresentable {
    let coordinator: BrowserPageOverlayCoordinator?
    let id: String
    /// Set for a floating overlay: what its panel shows.
    let floatingContent: AnyView?

    func makeNSView(context: Context) -> BrowserPageOverlayAnchorView {
        let view = BrowserPageOverlayAnchorView()
        view.configure(coordinator: coordinator, id: id, floatingContent: floatingContent)
        return view
    }

    func updateNSView(_ view: BrowserPageOverlayAnchorView, context: Context) {
        view.configure(coordinator: coordinator, id: id, floatingContent: floatingContent)
    }

    static func dismantleNSView(_ view: BrowserPageOverlayAnchorView, coordinator: ()) {
        view.unregister()
    }
}

/// Registers with the coordinator while in a window and asks it to sync on
/// every frame, window and visibility change.
final class BrowserPageOverlayAnchorView: NSView {
    private weak var coordinator: BrowserPageOverlayCoordinator?
    private var id = ""
    private var hostingView: NSHostingView<AnyView>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(coordinator: BrowserPageOverlayCoordinator?, id: String, floatingContent: AnyView?) {
        if self.coordinator !== coordinator || self.id != id { unregister() }
        self.coordinator = coordinator
        self.id = id
        if let floatingContent {
            if let hostingView {
                hostingView.rootView = floatingContent
            } else {
                hostingView = NSHostingView(rootView: floatingContent)
            }
        } else {
            hostingView = nil
        }
        register()
    }

    func unregister() {
        guard let coordinator else { return }
        coordinator.unregisterOccluding(id: id)
        coordinator.unregisterFloating(id: id)
    }

    private func register() {
        guard let coordinator else { return }
        guard window != nil else {
            unregister()
            return
        }
        if let hostingView {
            coordinator.registerFloating(self, id: id, content: hostingView)
        } else {
            coordinator.registerOccluding(self, id: id)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        register()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        coordinator?.update()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        coordinator?.update()
    }

    override func viewDidHide() {
        super.viewDidHide()
        coordinator?.update()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        coordinator?.update()
    }
}
