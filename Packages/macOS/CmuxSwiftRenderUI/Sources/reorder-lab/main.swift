// Dev-only GUI lab for the reorderable drag interaction.
//
// Hosts a JS sidebar with a Reorderable list in a bare window so the drag
// can be iterated on with `swift run reorder-lab` (seconds) instead of an
// app build (minutes). Drive it with real mouse input or synthesized events;
// set CMUX_REORDER_DEBUG=1 to trace lift/crossing/drop on stderr.
import AppKit
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

let source = """
sidebar(() =>
  VStack({ spacing: 6 }, [
    Text("Reorder lab").font("headline"),
    Divider(),
    Reorderable(
      {
        items: () => data.items() ?? [],
        key: (w) => w.id,
        onMove: (id, index) => log("moved " + id + " -> " + index),
      },
      (w) =>
        (w().header
          ? HStack({ spacing: 6 }, [
              Image("chevron.down").font(10).color("tertiary"),
              Text(() => w().title).font(12).weight("semibold"),
            ])
              .padding(6)
              .frame({ maxWidth: "infinity" })
              .fixed()
              .block(() => w().block ?? null)
              .onTap(() => log("tapped header " + w().id))
          : HStack({ spacing: 8 }, [
              Circle({ size: 7 }).fill("accent"),
              Text(() => w().title).font(13),
              Spacer(),
            ])
              .padding(6)
              .cornerRadius(6)
              .background("#7f7f7f26")
              .frame({ maxWidth: "infinity" })
              .block(() => w().block ?? null)
              .paddingLeading(() => (w().block ? 18 : 6))
              .onTap(() => log("tapped " + w().id)))
    ),
  ])
)
"""

let items: SwiftValue = .array(
    (1...3).map { i in
        .object(["id": .string("row\(i)"), "title": .string("Row \(i) with some text")])
    } + [.object(["id": .string("hdr"), "title": .string("Section"), "header": .bool(true), "block": .string("hdr")])]
    + (4...5).map { i in
        .object(["id": .string("row\(i)"), "title": .string("Row \(i) with some text"), "block": .string("hdr")])
    } + [.object(["id": .string("row6"), "title": .string("Row 6 with some text")])]
)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dispatch = SidebarActionDispatch { action in
            FileHandle.standardError.write(Data("lab action: \(action)\n".utf8))
        }
        let view = VStack(spacing: 0) {
            // Control probe: if this native Button doesn't react to injected
            // events, the injection is broken, not the sidebar runtime.
            Button("probe") {
                FileHandle.standardError.write(Data("lab probe button fired\n".utf8))
            }
            .padding(.top, 4)
            ScrollView {
                JSSidebarHostView(
                    source: source,
                    dataContext: ["items": items],
                    dispatch: dispatch
                )
                .padding(12)
            }
        }
        .frame(width: 280, height: 480)

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 280, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "reorder-lab"
        window.contentView = NSHostingView(rootView: view)
        // Pin to the main display: synthesized pointer events must land on
        // the same display the driver computes coordinates for.
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + 500, y: screen.frame.minY + 250))
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        // Self-driving drag: CMUX_LAB_AUTODRAG="fromY,toY,ms" sends a scripted
        // mouseDown/mouseDragged/mouseUp sequence through window.sendEvent at
        // 60 Hz, exercising the exact SwiftUI gesture path with no synthetic-
        // event permissions or app-activation flakiness. Ys are points from
        // the CONTENT top; x is the content middle.
        if let spec = ProcessInfo.processInfo.environment["CMUX_LAB_AUTODRAG"] {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 3 {
                let delay = parts.count >= 4 ? parts[3] / 1000 : 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.runAutoDrag(fromY: parts[0], toY: parts[1], durationMS: parts[2])
                }
            }
        }
    }

    private var dragTimer: Timer?

    private func runAutoDrag(fromY: CGFloat, toY: CGFloat, durationMS: Double) {
        guard let window, let content = window.contentView else { return }
        let x: CGFloat = content.bounds.midX
        // Content-top-relative Y -> window (bottom-left origin) coordinates.
        func windowPoint(_ yFromTop: CGFloat) -> NSPoint {
            // NSHostingView is flipped (origin top-left); a plain NSView is not.
            let inContent = NSPoint(x: x, y: content.isFlipped ? yFromTop : content.bounds.height - yFromTop)
            return content.convert(inContent, to: nil)
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint, clickCount: Int = 1) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            ) else { return }
            // postEvent enqueues on the app's event loop, the same entry real
            // input takes; sendEvent-on-window skips routing SwiftUI needs.
            NSApp.postEvent(event, atStart: false)
        }
        // Log what the down point actually hits, to separate coordinate bugs
        // from gesture-routing bugs.
        let downPoint = windowPoint(fromY)
        let hit = content.hitTest(content.convert(downPoint, from: nil))
        FileHandle.standardError.write(Data("lab hitTest at \(downPoint) -> \(hit.map { String(describing: type(of: $0)) } ?? "nil")\n".utf8))
        let steps = max(2, Int(durationMS / 16.0))
        var step = 0
        FileHandle.standardError.write(Data("lab autodrag start fromY=\(fromY) toY=\(toY)\n".utf8))
        send(.leftMouseDown, windowPoint(fromY))
        // The mouseDown puts AppKit controls into a nested mouse-tracking
        // runloop; a default-mode timer would starve and the gesture would
        // never see the drag/up events. Register in common + eventTracking.
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                step += 1
                let t = CGFloat(step) / CGFloat(steps)
                let y = fromY + (toY - fromY) * min(1, t)
                if step >= steps {
                    self?.dragTimer?.invalidate()
                    self?.dragTimer = nil
                    send(.leftMouseUp, windowPoint(y))
                    FileHandle.standardError.write(Data("lab autodrag end\n".utf8))
                } else {
                    send(.leftMouseDragged, windowPoint(y))
                }
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        RunLoop.current.add(timer, forMode: .eventTracking)
        dragTimer = timer
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
