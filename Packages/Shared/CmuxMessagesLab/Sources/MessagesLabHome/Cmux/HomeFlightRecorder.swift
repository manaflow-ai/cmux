import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The app's side of MessagesLab's flight recorder (Vendor/appkit-native/
/// FlightRecorder.swift): its policy, its log folder, "Save Last 10 Seconds",
/// and the helpers it calls from MessagesLab files that are not vendored
/// (FlashCheck's two presented-frame checks, LiveProbes' JSON write, Bench's
/// load average, LiveRecord's window grab and JPEG write), copied unchanged
/// from the pinned commit.
///
/// Off until the app sets the policy: CmuxNext turns it on by default in DEV
/// builds, behind Debug Settings opt-ins in NIGHTLY (recording, and window
/// captures separately), and never in Release or RC.
public enum HomeFlightRecorder {
    /// Whether the recorder samples after a send and dumps on a finding. Read live.
    nonisolated(unsafe) public static var isEnabled: () -> Bool = { false }
    /// Whether a dump also writes window captures (about 0.5 s of frames). Read live.
    nonisolated(unsafe) public static var capturesWindow: () -> Bool = { false }
    /// The folder under ~/Library/Logs the dumps go to (`blink-<time>/`).
    nonisolated(unsafe) public static var logFolder = "cmux"

    /// Writes the last ~10 s now ("Save Last 10 Seconds"); the dump folder,
    /// or nil when the recorder is off or no Home transcript is shown.
    @MainActor @discardableResult
    public static func saveLastSeconds() -> String? {
        guard FlightRecorder.enabled else { return nil }
        let before = FlightRecorder.shared.dumps.count
        FlightRecorder.shared.saveLastSeconds(nil)
        return FlightRecorder.shared.dumps.count > before ? FlightRecorder.shared.dumps.last : nil
    }

    // MARK: Helpers from MessagesLab files that are not vendored

    /// FlashCheck.coverageGaps(_:minGap:presented: true), except that the
    /// empty space above the loaded transcript's first row is no gap: a
    /// conversation shorter than the pane leaves it (MessagesLab's checks run
    /// on a full fixture transcript; a new Chief conversation dumped on its
    /// first send).
    static func coverageGaps(_ view: MessagesWindowView, minGap: CGFloat = 40) -> [(CGFloat, CGFloat)] {
        let top = Fixture.headerHeight, bottom = view.fieldTop - 4
        let firstKey = view.model.rows.first?.spec.key
        var showsFirst = false
        var spans: [(CGFloat, CGFloat)] = []
        for case let cell as RowCell in view.collection.visibleCells where !cell.isHidden {
            if cell.spec?.key == firstKey { showsFirst = true }
            let l = cell.layer.presentation() ?? cell.layer
            let f = l.convert(l.bounds, to: view.layer.presentation() ?? view.layer)
            spans.append((f.minY, f.maxY))
        }
        spans.sort { $0.0 < $1.0 }
        var gaps: [(CGFloat, CGFloat)] = []
        var y = top
        for (a, b) in spans where b > y {
            if a - y > minGap, a > top { gaps.append((y, min(a, bottom))) }
            y = max(y, b)
            if y >= bottom { break }
        }
        if bottom - y > minGap { gaps.append((y, bottom)) }
        if showsFirst { gaps.removeAll { $0.0 == top } }
        return gaps.filter { $0.1 - $0.0 > minGap }
    }

    /// FlashCheck.unfilledOutgoing(_:presented: true).
    static func unfilledOutgoing(_ view: MessagesWindowView) -> [String] {
        var out: [String] = []
        let root = view.layer.presentation() ?? view.layer
        for case let cell as RowCell in view.collection.visibleCells where !cell.isHidden && !cell.fillContainer.isHidden {
            guard let spec = cell.spec, case .part = spec.kind, RowDraw.needsFill(spec) else { continue }
            let cl = cell.layer.presentation() ?? cell.layer
            let body = cl.convert(RowDraw.bodyRect(spec), to: root)
            guard body.maxY > Fixture.headerHeight, body.minY < view.fieldTop else { continue }
            let g = cell.fillGradient.presentation() ?? cell.fillGradient
            let gr = g.convert(g.bounds, to: root)
            if !gr.insetBy(dx: -0.5, dy: -0.5).contains(body) { out.append("\(spec.key) body \(Int(body.minY))-\(Int(body.maxY)) fill \(Int(gr.minY))-\(Int(gr.maxY))") }
        }
        return out
    }

    /// LiveProbes.write.
    static func writeJSON(_ obj: Any, _ path: String) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Bench.loadAverage.
    static var loadAverage: Double {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return (l[0] * 100).rounded() / 100
    }

    /// LiveSendRun.grab: the window server's composite of one window.
    static func grab(_ wid: UInt32) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)(.null, 8, wid, 1 | 8)?.takeRetainedValue()
    }

    /// LiveSendRun.writeJPEG.
    static func writeJPEG(_ img: CGImage, _ path: String) {
        guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(d)
    }
}
