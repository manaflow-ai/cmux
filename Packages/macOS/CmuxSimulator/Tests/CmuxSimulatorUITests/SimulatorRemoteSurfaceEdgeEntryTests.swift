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
        let movedPoint = try #require(harness.pointerEvents.dropFirst().first?.primary)
        #expect(abs(movedPoint.x - 0.5) < 0.000_001)
        #expect(abs(movedPoint.y - 0.9) < 0.000_001)
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

    @Test("A bottom-corner entry preserves the crossed bottom edge")
    func bottomCornerDrag() throws {
        let harness = try SurfaceHarness()
        defer { harness.close() }

        harness.view.mouseDown(with: harness.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 10, y: 10)
        ))
        harness.view.mouseDragged(with: harness.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 30, y: 50)
        ))
        harness.view.mouseUp(with: harness.mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 60, y: 100)
        ))

        #expect(harness.pointerEvents.map(\.phase) == [.began, .moved, .ended])
        let beganPoint = try #require(harness.pointerEvents.first?.primary)
        #expect(abs(beganPoint.x) < 0.000_001)
        #expect(abs(beganPoint.y - 1) < 0.000_001)
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

    @Test("The stage monitor passes events through while forwarding an entering drag")
    func stageMonitorForwardsDragWithoutConsumingEvents() throws {
        let harness = try SurfaceHarness()
        defer { harness.close() }
        let down = harness.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 220, y: -12)
        )
        let dragged = harness.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 220, y: 110)
        )
        let up = harness.mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 220, y: 190)
        )

        #expect(harness.view.handleStagePointerEvent(down) === down)
        #expect(harness.pointerEvents.isEmpty)
        #expect(harness.view.handleStagePointerEvent(dragged) === dragged)
        #expect(harness.view.handleStagePointerEvent(up) === up)

        #expect(harness.pointerEvents.map(\.phase) == [.began, .moved, .ended])
        #expect(harness.pointerEvents.first?.edge == .bottom)
    }

    @Test("The stage monitor ignores drags that start beyond its halo")
    func stageMonitorIgnoresDistantDrag() throws {
        let harness = try SurfaceHarness()
        defer { harness.close() }

        _ = harness.view.handleStagePointerEvent(harness.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 220, y: -23)
        ))
        _ = harness.view.handleStagePointerEvent(harness.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 220, y: 110)
        ))
        _ = harness.view.handleStagePointerEvent(harness.mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 220, y: 190)
        ))

        #expect(harness.pointerEvents.isEmpty)
    }

    @Test("Only the input-eligible surface forwards a same-window halo drag")
    func hiddenSameWindowSurfaceDoesNotForwardDrag() throws {
        let bounds = CGRect(x: 0, y: 0, width: 460, height: 840)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: bounds)
        let active = try SurfaceHarness(window: window, pointerInputEnabled: true)
        let hidden = try SurfaceHarness(window: window, pointerInputEnabled: false)
        defer {
            active.close()
            hidden.close()
            window.orderOut(nil)
        }
        let events = [
            active.mouseEvent(type: .leftMouseDown, location: CGPoint(x: 220, y: -12)),
            active.mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 220, y: 110)),
            active.mouseEvent(type: .leftMouseUp, location: CGPoint(x: 220, y: 190)),
        ]

        for event in events {
            _ = hidden.view.handleStagePointerEvent(event)
            _ = active.view.handleStagePointerEvent(event)
        }

        #expect(active.pointerEvents.map(\.phase) == [.began, .moved, .ended])
        #expect(hidden.pointerEvents.isEmpty)
        #expect(hidden.view.stagePointerMonitor == nil)
    }

    @Test("Only the frontmost eligible surface accepts an overlapping halo drag")
    func overlappingEligibleSurfacesUseHostHitTest() throws {
        let bounds = CGRect(x: 0, y: 0, width: 460, height: 840)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: bounds)
        let frontmost = try SurfaceHarness(window: window, pointerInputEnabled: true)
        let obscured = try SurfaceHarness(window: window, pointerInputEnabled: true)
        frontmost.view.pointerEntryEventFilter = { _ in true }
        obscured.view.pointerEntryEventFilter = { _ in false }
        defer {
            frontmost.close()
            obscured.close()
            window.orderOut(nil)
        }
        let events = [
            frontmost.mouseEvent(type: .leftMouseDown, location: CGPoint(x: 220, y: -12)),
            frontmost.mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 220, y: 110)),
            frontmost.mouseEvent(type: .leftMouseUp, location: CGPoint(x: 220, y: 190)),
        ]

        for event in events {
            _ = obscured.view.handleStagePointerEvent(event)
            _ = frontmost.view.handleStagePointerEvent(event)
        }

        #expect(frontmost.pointerEvents.map(\.phase) == [.began, .moved, .ended])
        #expect(obscured.pointerEvents.isEmpty)
    }

    @Test("Losing input eligibility cancels an active touch and removes the monitor")
    func inputEligibilityLossCancelsTouch() throws {
        let harness = try SurfaceHarness()
        defer { harness.close() }

        harness.view.mouseDown(with: harness.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 220, y: 110)
        ))
        harness.view.setPointerInputEnabled(false)

        #expect(harness.pointerEvents.map(\.phase) == [.began, .cancelled])
        #expect(harness.view.stagePointerMonitor == nil)
    }

    @Test("Tearing down the surface removes its stage monitor")
    func teardownRemovesStageMonitor() throws {
        let harness = try SurfaceHarness()
        #expect(harness.view.stagePointerMonitor != nil)

        harness.close()

        #expect(harness.view.stagePointerMonitor == nil)
    }
}

@MainActor
private final class SurfaceHarness {
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
        if ownsWindow {
            window.orderOut(nil)
        }
    }
}
