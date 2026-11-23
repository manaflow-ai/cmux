#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileSupport
import UIKit

/// Records how the two pages were drawn, including frames while XCTest waits for
/// taps, swipes and navigation to settle. One file per launch, exposed like KeyboardPinTrace.
@MainActor
public final class WorkspaceShiftTrace {
    private static var recorder: WorkspaceShiftTrace?
    private let writes = DispatchQueue(label: "dev.cmux.mobile.workspace-shift", qos: .utility)
    private let handle: FileHandle
    private let probe = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let geometry = MobileKeyboardProbe()
    private let start = CACurrentMediaTime()
    private var token: FrameClock.Token?

    public static func startIfRequested() {
        guard WorkspaceShiftLandmark.enabled, recorder == nil else { return }
        recorder = WorkspaceShiftTrace()
    }

    private init?() {
        let url = FrameLogFile.url(in: .cachesDirectory, "workspace-shift.jsonl")
        guard (try? Data().write(to: url, options: .atomic)) != nil,
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        probe.isUserInteractionEnabled = false
        probe.alpha = 0.02
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "debug.workspace-shift"
        probe.accessibilityLabel = "Workspace frame trace"
        probe.accessibilityValue = url.path
        token = FrameClock.shared.subscribe { [weak self] tick in self?.sample(tick) }
    }

    private struct Frame: Encodable, Sendable {
        let t: Double
        let nominal: Double
        let scale: CGFloat
        let keyboardTop: CGFloat?
        var safeBottom: CGFloat
        var tabBarTop: CGFloat?
        var boxes = [String: [CGFloat]]()
        var pageOffsetX = [String: CGFloat]()
    }

    private func sample(_ tick: FrameClock.Tick) {
        // One test launches once for its push and pop. Also bound a stalled test.
        if tick.timestamp - start > 180 {
            if let token { FrameClock.shared.unsubscribe(token) }
            token = nil
            return
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) else { return }
        if probe.window !== window { window.addSubview(probe) }
        let keyboard = geometry.drawnFrame(in: window)
        var frame = Frame(t: tick.timestamp, nominal: tick.nominal, scale: window.traitCollection.displayScale,
                          keyboardTop: keyboard?.minY, safeBottom: window.safeAreaInsets.bottom)
        let landmarks = WorkspaceShiftLandmark.registered(in: window)
        // UIKit reveals the list from under the workspace. A row mounted behind
        // the opaque workspace has not appeared yet, even if it is in the window.
        let workspace = landmarks.first { $0.id.hasPrefix("page.") }.flatMap { navigationPage(of: $0.view) }
        let cover = workspace.flatMap { visibleRect(of: $0.view, in: window) }
        for (id, view) in landmarks {
            guard let page = navigationPage(of: view), let visible = visibleRect(of: view, in: window),
                  keyboard?.contains(visible) != true else { continue }
            if id.hasPrefix("workspace.row."), cover?.contains(visible) == true { continue }
            let translation = geometry.onScreen(page.view, in: window).minX
            var rect = geometry.onScreen(view, in: window)
            rect.origin.x -= translation
            if id.hasPrefix("content."), let scroll = view as? UIScrollView {
                // The first content line, including the safe-area inset or a
                // scroll-to-bottom correction inside an otherwise unmoving viewport.
                rect.origin.y -= (scroll.layer.presentation() ?? scroll.layer).bounds.minY
                rect.size.height = 0
            }
            frame.boxes[id] = [rect.minX, rect.minY, rect.width, rect.height]
            frame.pageOffsetX[id] = translation
            if id.hasPrefix("page.") { frame.safeBottom = page.view.safeAreaInsets.bottom }
            if frame.tabBarTop == nil, let bar = page.tabBarController?.tabBar, !bar.isHidden {
                frame.tabBarTop = geometry.onScreen(bar, in: window).minY
            }
        }
        writes.async { [frame, handle] in
            guard var data = try? JSONEncoder().encode(frame) else { return }
            data.append(0x0A)
            try? handle.write(contentsOf: data)
        }
    }

    /// The actual child of the navigation controller. Its horizontal translation
    /// is the push/pop; the element's x within it and y in the window are layout.
    private func navigationPage(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let page = current as? UIViewController, page.parent is UINavigationController { return page }
            responder = current.next
        }
        return nil
    }

    private func visibleRect(of view: UIView, in window: UIWindow) -> CGRect? {
        var rect = geometry.onScreen(view, in: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            let layer = current.layer.presentation() ?? current.layer
            guard !layer.isHidden, layer.opacity > 0.01 else { return nil }
            if current.clipsToBounds {
                rect = rect.intersection(geometry.onScreen(current, in: window))
            }
            guard !rect.isEmpty else { return nil }
            ancestor = current.superview
        }
        return rect
    }
}
#endif
