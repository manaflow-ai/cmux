public import AppKit

/// Debug > Motion Lab... (MOTION LAB, branch motion-lab-nomerge only, never merged): the item that shows
/// ``MotionLabWindow`` in DEBUG and bench builds; no item in any other build. The item holds its window
/// (`representedObject`), one per main menu.
@MainActor public final class MotionLabMenu {
    public init() {}

    public var items: [NSMenuItem] {
        #if DEBUG || CMUX_BENCH_HOOKS
        let window = MotionLabWindow(lab: DesignSettings.shared.motionLab)
        let item = NSMenuItem(title: "Motion Lab\u{2026}", action: #selector(MotionLabWindow.show), keyEquivalent: "")
        item.target = window
        item.representedObject = window
        return [item]
        #else
        return []
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// MOTION LAB window (Debug > Motion Lab..., branch motion-lab-nomerge only, never merged): live pickers for the close,
/// zoom and pin motion and their curves (``MotionLab``). Each change applies to the next action, with no restart. English
/// only, as the other Debug-only lab windows on film branches.
@MainActor final class MotionLabWindow: NSObject, NSWindowDelegate {
    private let lab: MotionLab
    private var window: NSWindow?
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let pinNote = NSTextField(labelWithString: "")
    private var rows: [Row] = []

    /// One motion's controls: variant, curve, time override.
    private final class Row: NSObject {
        let variant = NSPopUpButton()
        let curve = NSPopUpButton()
        let override = NSButton(checkboxWithTitle: "Time", target: nil, action: nil)
        let slider = NSSlider(value: 150, minValue: 60, maxValue: 300, target: nil, action: nil)
        let value = NSTextField(labelWithString: "150 ms")
    }

    init(lab: MotionLab) {
        self.lab = lab
        super.init()
    }

    @objc func show() {
        if self.window == nil { lab.seed() }
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Motion Lab"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let close = row(MotionLab.Close.allCases.map { $0.title }, selected: MotionLab.Close.allCases.firstIndex(of: lab.close) ?? 0,
                        track: lab.closeTrack)
        let zoom = row(MotionLab.Zoom.allCases.map { $0.title }, selected: MotionLab.Zoom.allCases.firstIndex(of: lab.zoom) ?? 0,
                       track: lab.zoomTrack)
        let pin = row(MotionLab.Pin.allCases.map { $0.title }, selected: MotionLab.Pin.allCases.firstIndex(of: lab.pin) ?? 0,
                      track: lab.pinTrack)
        rows = [close, zoom, pin]
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Close"), close.variant, close.curve, close.override, close.slider, close.value],
            [NSTextField(labelWithString: "Zoom"), zoom.variant, zoom.curve, zoom.override, zoom.slider, zoom.value],
            [NSTextField(labelWithString: "Pin"), pin.variant, pin.curve, pin.override, pin.slider, pin.value],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        let slow = NSButton(checkboxWithTitle: "Slow motion x4", target: self, action: #selector(toggleSlow(_:)))
        slow.state = lab.slow ? .on : .off
        let hold = NSButton(checkboxWithTitle: "Redraw hold", target: self, action: #selector(toggleHold(_:)))
        hold.state = lab.redrawHold ? .on : .off
        let copy = NSButton(title: "Copy my picks", target: self, action: #selector(copyPicks))
        let notes = NSTextField(wrappingLabelWithString:
            "Each pick applies to the next close, zoom or pin. Zoom curves play on Z4 (Z0 is the current zoom). "
                + "V1 is instant: no curve. The pin curve sets the move spring, which sidebar rows and tabs use too.")
        let stack = NSStackView(views: [grid, NSStackView(views: [slow, hold, copy]), pinNote, summary, notes])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            summary.widthAnchor.constraint(lessThanOrEqualToConstant: 588),
            notes.widthAnchor.constraint(lessThanOrEqualToConstant: 588),
        ])
        window.contentView = content
        window.center()
        return window
    }

    private func row(_ variants: [String], selected: Int, track: MotionLab.Track) -> Row {
        let row = Row()
        row.variant.addItems(withTitles: variants)
        row.variant.selectItem(at: selected)
        row.curve.addItems(withTitles: MotionLab.Curve.allCases.map { $0.title })
        row.curve.selectItem(at: MotionLab.Curve.allCases.firstIndex(of: track.curve) ?? 0)
        row.override.state = track.milliseconds == nil ? .off : .on
        row.slider.doubleValue = track.milliseconds ?? 150
        row.slider.isContinuous = true
        for control in [row.variant, row.curve, row.override, row.slider] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }
        return row
    }

    @objc private func changed() {
        guard rows.count == 3 else { return }
        func track(_ row: Row) -> MotionLab.Track {
            let curve = MotionLab.Curve.allCases[max(0, row.curve.indexOfSelectedItem)]
            return MotionLab.Track(curve: curve, milliseconds: row.override.state == .on ? row.slider.doubleValue.rounded() : nil)
        }
        lab.close = MotionLab.Close.allCases[max(0, rows[0].variant.indexOfSelectedItem)]
        lab.closeTrack = track(rows[0])
        lab.zoom = MotionLab.Zoom.allCases[max(0, rows[1].variant.indexOfSelectedItem)]
        lab.zoomTrack = track(rows[1])
        lab.pin = MotionLab.Pin.allCases[max(0, rows[2].variant.indexOfSelectedItem)]
        lab.pinTrack = track(rows[2])
        lab.apply()
        refresh()
    }

    @objc private func toggleSlow(_ sender: NSButton) {
        lab.slow = sender.state == .on
        lab.apply()
        refresh()
    }

    @objc private func toggleHold(_ sender: NSButton) {
        lab.redrawHold = sender.state == .on
        refresh()
    }

    @objc private func copyPicks() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lab.picks, forType: .string)
    }

    private func refresh() {
        for row in rows {
            row.slider.isEnabled = row.override.state == .on
            row.value.stringValue = row.override.state == .on ? "\(Int(row.slider.doubleValue.rounded())) ms" : "curve"
        }
        pinNote.stringValue = lab.pin == .p1 && lab.pinSpringOnly
            ? "Pin: P1 is spring only. This bezier curve plays as K6." : ""
        summary.stringValue = "Now: " + lab.picks
    }
}
#endif
