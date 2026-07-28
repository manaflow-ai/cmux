import AppKit
import CmuxSimulator
@testable import CmuxSimulatorUI

@MainActor
final class SimulatorRemoteSurfaceEdgeEntryHarness {
    let view: SimulatorRemoteSurfaceView
    let window: NSWindow
    private let ownsWindow: Bool
    private(set) var pointerEvents: [SimulatorPointerEvent] = []

    init(
        window sharedWindow: NSWindow? = nil,
        pointerInputEnabled: Bool = true
    ) throws {
        let bounds = CGRect(x: 0, y: 0, width: 460, height: 840)
        view = SimulatorRemoteSurfaceView(frame: bounds)
        if let sharedWindow {
            window = sharedWindow
            ownsWindow = false
            sharedWindow.contentView?.addSubview(view)
        } else {
            let ownedWindow = NSWindow(
                contentRect: bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window = ownedWindow
            ownsWindow = true
            ownedWindow.contentView = view
        }
        view.setPointerInputEnabled(pointerInputEnabled)
        view.display = SimulatorDisplayMetadata(
            width: 400,
            height: 800,
            orientation: .portrait,
            scale: 1
        )
        view.chrome = SimulatorDeviceChromeProfile(
            screenWidth: 400,
            screenHeight: 800,
            insets: .init(top: 10, leading: 20, bottom: 30, trailing: 40),
            devicePadding: .zero,
            cornerRadius: 30,
            screenCornerRadius: 10,
            assets: [:],
            compositeURL: nil,
            buttons: []
        )
        view.onMessage = { [weak self] message in
            guard case let .pointer(event) = message else { return }
            self?.pointerEvents.append(event)
        }
    }

    func mouseEvent(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    func close() {
        view.teardown()
        view.removeFromSuperview()
        if ownsWindow { window.orderOut(nil) }
    }
}
