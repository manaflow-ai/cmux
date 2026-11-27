// LayoutShiftCounter (the pure frame-to-frame rule) lives in CmuxMobileDesignCore, which builds and tests
// on Linux; re-exported so `import CmuxMobileDesign` keeps it.
@_exported import CmuxMobileDesignCore

#if os(iOS)
import QuartzCore
import SwiftUI

/// With `-cmux-placeholder-markers` (the ios-placeholder-bounds suite's launch argument), counts
/// layout shifts of every `.layoutShiftTracked` row once per display frame and shows the counts as
/// one JSON object in the label `debug.layout-shift` (`LayoutShiftProbeLabel`, at the app's root).
/// Nothing runs without that argument.
@MainActor
@Observable
public final class LayoutShiftProbe {
    public static let shared: LayoutShiftProbe? = PlaceholderBound.markersEnabled ? LayoutShiftProbe() : nil

    public private(set) var text = "{}"

    @ObservationIgnored private var rows: [String: LayoutShiftCounter.Row] = [:]
    @ObservationIgnored private var counter = LayoutShiftCounter()
    @ObservationIgnored private var link: CADisplayLink?

    private init() {
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func set(_ id: String, _ row: LayoutShiftCounter.Row?) { rows[id] = row }

    fileprivate func tick() {
        let frames = counter.frames, shifts = counter.shiftFrames
        counter.frame(rows)
        guard counter.frames != frames, counter.frames == 1 || counter.shiftFrames != shifts || counter.frames % 30 == 0 else { return }
        let json: [String: Any] = [
            "frames": counter.frames, "shiftFrames": counter.shiftFrames,
            "shiftedRows": counter.shiftedRows, "lastMoved": counter.lastMoved, "rows": rows.count,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        text = String(data: data, encoding: .utf8) ?? "{}"
    }

    private final class Ticker: NSObject {
        weak var probe: LayoutShiftProbe?
        init(_ probe: LayoutShiftProbe) { self.probe = probe }
        /// Reads the weak reference here, so the main-actor closure captures the (Sendable,
        /// main-actor) probe and not this non-Sendable target.
        @objc func tick() {
            let probe = probe
            MainActor.assumeIsolated { probe?.tick() }
        }
    }
}

/// The probe's label, mounted once at the app's root.
public struct LayoutShiftProbeLabel: View {
    public init() {}

    public var body: some View {
        if let probe = LayoutShiftProbe.shared {
            Text(probe.text)
                .lineLimit(1)
                .frame(width: 4, height: 4)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.layout-shift")
                .accessibilityLabel(probe.text)
        }
    }
}

private struct LayoutShiftTracked: ViewModifier {
    let id: String
    let space: LayoutShiftCounter.Space

    func body(content: Content) -> some View {
        if let probe = LayoutShiftProbe.shared {
            let space = space
            content
                .onGeometryChange(for: CGRect.self) { proxy in
                    space == .scrollContent ? proxy.frame(in: .scrollView) : proxy.frame(in: .global)
                } action: { rect in
                    probe.set(id, .init(rect, space))
                }
                .onDisappear { probe.set(id, nil) }
        } else {
            content
        }
    }
}

public extension View {
    /// Marks a row or card whose frame the layout-shift count watches (`LayoutShiftCounter`);
    /// nothing without `-cmux-placeholder-markers`. `id` is unique on screen.
    func layoutShiftTracked(_ id: String, in space: LayoutShiftCounter.Space = .scrollContent) -> some View {
        modifier(LayoutShiftTracked(id: id, space: space))
    }
}
#endif
