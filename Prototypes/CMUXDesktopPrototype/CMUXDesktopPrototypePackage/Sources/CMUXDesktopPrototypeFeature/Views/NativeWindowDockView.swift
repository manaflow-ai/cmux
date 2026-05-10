import AppKit
import SwiftUI

struct NativeWindowDockView: NSViewRepresentable {
    let onFrameChange: (NativeWindowSlotFrame) -> Void

    func makeNSView(context: Context) -> NativeWindowDockNSView {
        let view = NativeWindowDockNSView()
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ nsView: NativeWindowDockNSView, context: Context) {
        nsView.onFrameChange = onFrameChange
        nsView.reportFrame()
    }
}

final class NativeWindowDockNSView: NSView {
    var onFrameChange: ((NativeWindowSlotFrame) -> Void)?

    private var lastFrame: NativeWindowSlotFrame?
    private var windowMoveObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        installWindowObservers()
        reportFrame()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeWindowObservers()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        reportFrame()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportFrame()
    }

    func reportFrame() {
        guard let window, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let windowRect = convert(bounds, to: nil)
        let cocoaFrame = window.convertToScreen(windowRect)
        let slotFrame = NativeWindowSlotFrame(
            quartzFrame: quartzFrame(fromCocoaFrame: cocoaFrame),
            cocoaFrame: cocoaFrame,
            isLiveResize: inLiveResize
        )

        guard lastFrame != slotFrame else {
            return
        }

        lastFrame = slotFrame
        Task { @MainActor [onFrameChange] in
            onFrameChange?(slotFrame)
        }
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else {
            return
        }

        let center = NotificationCenter.default
        windowMoveObserver = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reportFrame()
            }
        }
        windowResizeObserver = center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reportFrame()
            }
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        if let windowMoveObserver {
            center.removeObserver(windowMoveObserver)
        }
        if let windowResizeObserver {
            center.removeObserver(windowResizeObserver)
        }
        windowMoveObserver = nil
        windowResizeObserver = nil
    }

    private func quartzFrame(fromCocoaFrame frame: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.max(by: { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }) else {
            return frame
        }

        let displayFrame = displayBounds(for: screen)
        let screenFrame = screen.frame
        return CGRect(
            x: displayFrame.minX + (frame.minX - screenFrame.minX),
            y: displayFrame.minY + (screenFrame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        ).integral
    }

    private func displayBounds(for screen: NSScreen) -> CGRect {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.frame
        }
        return CGDisplayBounds(CGDirectDisplayID(displayID.uint32Value))
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else {
            return 0
        }
        return width * height
    }
}
