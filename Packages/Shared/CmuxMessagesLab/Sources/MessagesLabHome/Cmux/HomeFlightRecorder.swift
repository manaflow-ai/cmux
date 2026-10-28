import AppKit
import ImageIO
import CmuxSafeConcurrency
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
public struct HomeFlightRecorder {
    public init() {}
    /// Whether the recorder samples after a send and dumps on a finding. Read live.
    public static var isEnabled: @Sendable () -> Bool {
        get { policy.withLock { $0.isEnabled } }
        set { policy.withLock { $0.isEnabled = newValue } }
    }
    /// Whether a dump also writes window captures (about 0.5 s of frames). Read live.
    public static var capturesWindow: @Sendable () -> Bool {
        get { policy.withLock { $0.capturesWindow } }
        set { policy.withLock { $0.capturesWindow = newValue } }
    }
    /// The folder under ~/Library/Logs the dumps go to (`blink-<time>/`).
    public static var logFolder: String {
        get { policy.withLock { $0.logFolder } }
        set { policy.withLock { $0.logFolder = newValue } }
    }

    /// The app's policy (it was three unchecked globals). The app sets it once
    /// at launch; the recorder reads it after a send, from main and the dump queue.
    private struct Policy: Sendable {
        var isEnabled: @Sendable () -> Bool = { false }
        var capturesWindow: @Sendable () -> Bool = { false }
        var logFolder = "cmux"
    }
    // Lock carve-out: one launch write and one read per send or dump; no work under the lock.
    private static let policy = Mutex(Policy())

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

    /// FlashCheck.coverageGaps(_:minGap:presented: true). Since MessagesLab
    /// 69f4256 the space above the conversation's first message is no gap
    /// (a short or new conversation; a new Chief conversation dumped on its
    /// first send).
    static func coverageGaps(_ view: MessagesWindowView, minGap: CGFloat = 40) -> [(CGFloat, CGFloat)] {
        let top = view.visibleTop, bottom = view.fieldTop - 4
        var spans: [(CGFloat, CGFloat)] = []
        // The space above the conversation's first message is empty by design
        // (a short or new conversation): coverage starts at that row.
        let firstKey = view.store.state.windowStart == 0 ? view.model.rows.first?.spec.key : nil
        if view.store.state.windowStart == 0 && view.model.count == 0 { return [] }
        var start = top
        for case let cell as RowCell in view.collection.visibleCells where !cell.isHidden {
            let l = cell.layer.presentation() ?? cell.layer
            let f = l.convert(l.bounds, to: view.layer.presentation() ?? view.layer)
            spans.append((f.minY, f.maxY))
            if let firstKey, cell.spec?.key == firstKey { start = max(top, f.minY) }
        }
        spans.sort { $0.0 < $1.0 }
        var gaps: [(CGFloat, CGFloat)] = []
        var y = start
        for (a, b) in spans where b > y {
            if a - y > minGap, a > top { gaps.append((y, min(a, bottom))) }
            y = max(y, b)
            if y >= bottom { break }
        }
        if bottom - y > minGap { gaps.append((y, bottom)) }
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
            guard body.maxY > view.visibleTop, body.minY < view.fieldTop else { continue }
            let g = cell.fillGradient.presentation() ?? cell.fillGradient
            let gr = g.convert(g.bounds, to: root)
            if !gr.insetBy(dx: -0.5, dy: -0.5).contains(body) { out.append("\(spec.key) body \(CrashGuard.int(body.minY))-\(CrashGuard.int(body.maxY)) fill \(CrashGuard.int(gr.minY))-\(CrashGuard.int(gr.maxY))") } // crash program
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
        // SAFETY: getloadavg writes at most 3 doubles (its count argument), the array's count, during the call only.
        _ = unsafe getloadavg(&l, 3)
        return (l[0] * 100).rounded() / 100
    }

    /// LiveSendRun.grab: the window server's composite of one window.
    static func grab(_ wid: UInt32) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // SAFETY: RTLD_DEFAULT (-2) looks the symbol up in every loaded image; it is Core Graphics'
        // `CGImageRef CGWindowListCreateImage(CGRect, uint32_t, CGWindowID, uint32_t)`, which `Fn` spells exactly,
        // and it returns a +1 image (the Create rule), which takeRetainedValue balances once.
        guard let sym = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafe unsafeBitCast(sym, to: Fn.self)(.null, 8, wid, 1 | 8)?.takeRetainedValue()
    }

    /// LiveSendRun.writeJPEG.
    static func writeJPEG(_ img: CGImage, _ path: String) {
        guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(d)
    }
}
