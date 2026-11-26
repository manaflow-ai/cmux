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
              Text(() => w().title).font(13).lineLimit(1).truncation("tail").marquee(0.5),
              Spacer(),
              Text("42").font("caption2").color("tertiary"),
            ])
              .padding(6)
              .cornerRadius(6)
              .background("#7f7f7f26")
              .frame({ maxWidth: "infinity" })
              .block(() => w().block ?? null)
              .paddingLeading(() => (w().block ? 18 : 6))
              .onTap(() => log("tapped " + w().id))
              .onDoubleTap(() => log("double " + w().id)))
    ),
  ])
)
"""

let items: SwiftValue = .array(
    [.object(["id": .string("long"), "title": .string("An extremely long workspace title that certainly overflows the lab window width")])]
    + (1...3).map { i in
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
        FileHandle.standardError.write(Data("lab launched forceHover=\(ProcessInfo.processInfo.environment["CMUX_LAB_FORCE_HOVER"] ?? "0")\n".utf8))
        let dispatch = SidebarActionDispatch { action in
            FileHandle.standardError.write(Data("lab action: \(action)\n".utf8))
        }
        let view = LabRoot(source: source, dispatch: dispatch)
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
        // SwiftUI tap recognizers stop firing when the app is inactive (the
        // user clicked elsewhere while the drag was armed); AppKit buttons
        // keep working, which masked this. Re-activate before injecting.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        // durationMS < 0 encodes a DOUBLE CLICK test: two click pairs
        // 150 ms apart (clickCount 1 then 2, as AppKit generates them).
        if durationMS < 0 {
            send(.leftMouseDown, windowPoint(fromY))
            send(.leftMouseUp, windowPoint(fromY))
            let timer2 = Timer(timeInterval: 0.15, repeats: false) { _ in
                MainActor.assumeIsolated {
                    send(.leftMouseDown, windowPoint(fromY), clickCount: 2)
                    send(.leftMouseUp, windowPoint(fromY), clickCount: 2)
                    FileHandle.standardError.write(Data("lab doubleclick sent\n".utf8))
                }
            }
            RunLoop.current.add(timer2, forMode: .common)
            RunLoop.current.add(timer2, forMode: .eventTracking)
            dragTimer = timer2
            return
        }
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

/// Lab content: the sidebar host plus a probe button. With
/// CMUX_LAB_TOGGLE=1 the item list alternates every 2s between the full and a
/// reduced set, driving enter/exit slot animations for FPS sampling.
struct LabRoot: View {
    let source: String
    let dispatch: SidebarActionDispatch
    @State private var reduced = false
    /// CMUX_LAB_FORCE_HOVER=1 publishes sceneHovered=true to the whole tree:
    /// NSTrackingArea ignores synthesized events, so hover-gated behavior
    /// (marquee, fadeOnHover, showOnHover) is otherwise undrivable here.
    private let forceHover = ProcessInfo.processInfo.environment["CMUX_LAB_FORCE_HOVER"] == "1"

    private var context: [String: SwiftValue] {
        guard reduced, case let .array(all) = items else { return ["items": items] }
        return ["items": .array(Array(all.prefix(2)) + Array(all.suffix(1)))]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Control probe: if this native Button doesn't react to injected
            // events, the injection is broken, not the sidebar runtime.
            Button("probe") {
                FileHandle.standardError.write(Data("lab probe button fired\n".utf8))
            }
            .padding(.top, 4)
            ScrollView {
                JSSidebarHostView(
                    source: source,
                    dataContext: context,
                    dispatch: dispatch
                )
                .padding(12)
                .environment(\.sceneHovered, forceHover)
            }
        }
        .task {
            guard ProcessInfo.processInfo.environment["CMUX_LAB_TOGGLE"] == "1" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reduced.toggle()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
