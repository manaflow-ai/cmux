import AppKit
import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator remote surface edge entry")
struct SimulatorRemoteSurfaceEdgeEntryTests {
    @Test("A drag from the bottom bezel begins at the display edge")
    func bottomBezelDrag() throws {
        let harness = try SurfaceHarness()
        defer { harness.close() }

        harness.view.mouseDown(with: harness.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 220, y: 20)
        ))
        harness.view.mouseDragged(with: harness.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 220, y: 110)
        ))
        harness.view.mouseUp(with: harness.mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 220, y: 190)
        ))

        #expect(harness.pointerEvents.map(\.phase) == [.began, .moved, .ended])
        #expect(harness.pointerEvents.first?.primary == SimulatorPoint(x: 0.5, y: 1))
        #expect(harness.pointerEvents.first?.edge == .bottom)
        #expect(harness.pointerEvents.dropFirst().first?.primary == SimulatorPoint(x: 0.5, y: 0.9))
    }

    @Test("A drag from the stage halo enters through the bottom edge")
    func bottomStageHaloDrag() throws {
        let harness = try SurfaceHarness()
        defer { harness.close() }

        harness.view.mouseDown(with: harness.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 220, y: -12)
        ))
        harness.view.mouseDragged(with: harness.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 220, y: 110)
        ))
        harness.view.mouseUp(with: harness.mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 220, y: 190)
        ))

        #expect(harness.pointerEvents.map(\.phase) == [.began, .moved, .ended])
        #expect(harness.pointerEvents.first?.primary == SimulatorPoint(x: 0.5, y: 1))
        #expect(harness.pointerEvents.first?.edge == .bottom)
    }

    @Test("A click outside the display never becomes a touch")
    func outsideClick() throws {
        let harness = try SurfaceHarness()
        defer { harness.close() }

        harness.view.mouseDown(with: harness.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 220, y: -12)
        ))
        harness.view.mouseUp(with: harness.mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 220, y: -12)
        ))

        #expect(harness.pointerEvents.isEmpty)
    }
}

@MainActor
private final class SurfaceHarness {
    let view: SimulatorRemoteSurfaceView
    let window: NSWindow
    private(set) var pointerEvents: [SimulatorPointerEvent] = []

    init() throws {
        let bounds = CGRect(x: 0, y: 0, width: 460, height: 840)
        view = SimulatorRemoteSurfaceView(frame: bounds)
        window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
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
        window.orderOut(nil)
    }
}
