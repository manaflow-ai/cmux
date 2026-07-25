import AppKit
import SwiftUI

/// Owner-bound utility panel hosting the share-session chat.
///
/// The panel is always a child of the exact cmux window whose `TabManager`
/// owns the share. AppKit therefore moves it with that window and keeps it in
/// the same Space. Closing the panel only hides it; stopping the session goes
/// through the Stop button or the command palette.
@MainActor
final class ShareChatWindowController: NSObject {
    private let panel: NSPanel
    private weak var ownerWindow: NSWindow?
    private let visibleFrameOverride: NSRect?
    private var ownerObservers: [NSObjectProtocol] = []
    private var didPositionOnce = false

    init(
        controller: ShareSessionController,
        ownerWindow: NSWindow,
        visibleFrame: NSRect? = nil
    ) {
        self.ownerWindow = ownerWindow
        self.visibleFrameOverride = visibleFrame
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.shareSession")
        panel.title = String(localized: "share.chat.title", defaultValue: "Share Session")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 280, height: 340)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ShareChatView(controller: controller))
        observeOwnerWindow()
    }

    func show() {
        guard let ownerWindow else { return }
        if panel.parent !== ownerWindow {
            panel.parent?.removeChildWindow(panel)
            ownerWindow.addChildWindow(panel, ordered: .above)
        }
        if !didPositionOnce {
            didPositionOnce = true
            positionBottomTrailingOfOwner()
        } else {
            clampToVisibleFrame()
        }
        panel.orderFront(nil)
    }

    func isOwned(by window: NSWindow) -> Bool {
        ownerWindow === window
    }

    func close() {
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
    }

    private func observeOwnerWindow() {
        guard let ownerWindow else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            ownerObservers.append(center.addObserver(
                forName: name,
                object: ownerWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clampToVisibleFrame()
                }
            })
        }
        ownerObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: ownerWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        })
    }

    private func positionBottomTrailingOfOwner() {
        guard let ownerWindow else { return }
        let margin: CGFloat = 24
        panel.setFrameOrigin(NSPoint(
            x: ownerWindow.frame.maxX - panel.frame.width - margin,
            y: ownerWindow.frame.minY + margin
        ))
        clampToVisibleFrame()
    }

    private func clampToVisibleFrame() {
        guard let visibleFrame = resolvedVisibleFrame() else { return }
        let width = min(panel.frame.width, visibleFrame.width)
        let height = min(panel.frame.height, visibleFrame.height)
        let maximumX = visibleFrame.maxX - width
        let maximumY = visibleFrame.maxY - height
        let origin = NSPoint(
            x: min(max(panel.frame.minX, visibleFrame.minX), maximumX),
            y: min(max(panel.frame.minY, visibleFrame.minY), maximumY)
        )
        let clamped = NSRect(
            origin: origin,
            size: NSSize(width: width, height: height)
        )
        if panel.frame != clamped {
            panel.setFrame(clamped, display: false)
        }
    }

    private func resolvedVisibleFrame() -> NSRect? {
        visibleFrameOverride
            ?? ownerWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
    }

    isolated deinit {
        for observer in ownerObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
