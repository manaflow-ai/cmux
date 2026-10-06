import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Passive flight recorder for dogfood builds (always on in normal launches).
///
/// While anything animates, or for 10 s after a send, a display link of the
/// window samples every frame: each visible row (key, presented window rect,
/// presented opacity, bitmap present, bitmap identity), the morphs, the scroll
/// offset, the window's key state, its screen and refresh rate. A ring buffer
/// keeps the last ~10 s; store events (send, status, receive, typing, palette,
/// screen) are kept with their times. Idle: no display link, no work.
///
/// A detector runs on each sample during the 10 s after a send: a visible row
/// without a bitmap, an opaque row whose opacity dips, a row that jumps
/// against the others, a gap in the transcript, an outgoing bubble outside its
/// fill. On a finding it writes the ring buffer and a burst of window
/// captures (the window server's composite of this window, about 0.5 s) to
/// ~/Library/Logs/MessagesLab/blink-<time>/ and logs one line to stderr. At
/// most one dump per 15 s. "Save Last 10 Seconds" (Cmd+Shift+S) writes the
/// same without a finding.
final class FlightRecorder: NSObject {
    static let shared = FlightRecorder()
    // cmux: the app's policy (HomeFlightRecorder: DEV on, NIGHTLY opt-in, Release off), read live.
    static var enabled: Bool { HomeFlightRecorder.isEnabled() && !ProcessInfo.processInfo.arguments.contains("--no-flight-recorder") }

    struct Row { var key: String; var rect: CGRect; var opacity: Float; var hasBitmap: Bool; var bitmapID: Int; var age: Int }
    struct Sample {
        var t: CFTimeInterval
        var rows: [Row]
        var morphs: [(String, CGRect)]
        var offset: CGFloat
        var key: Bool
        var screen: String
        var hz: Int
        var gaps: [(CGFloat, CGFloat)]
        var unfilled: [String]
    }
    private var ring: [Sample] = []
    private var ringStart = 0
    private static let capacity = 1300                       // ~10 s at 120 Hz
    private var events: [(CFTimeInterval, String)] = []
    private weak var c: ChatController?
    private var link: CADisplayLink?
    private var lastSend: CFTimeInterval = -.infinity
    private var lastDump: CFTimeInterval = -.infinity
    private var ages: [String: Int] = [:]
    private var pendingFinding: (CFTimeInterval, String)?
    private(set) var dumps: [String] = []
    private static var bursts: [DispatchSourceTimer] = []

    // cmux: the pane's window comes and goes and the policy can switch on later: attach (from
    // ChatController.windowChanged) always, replacing the previous window's observers.
    private var observers: [NSObjectProtocol] = []
    func attach(_ c: ChatController) {
        self.c = c
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0) }
        observers = []
        guard let window = c.window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
                  NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(nc.addObserver(forName: n, object: window, queue: .main) { [weak self] note in
                self?.event(note.name.rawValue.replacingOccurrences(of: "NSWindow", with: ""))
                self?.kick()
            })
        }
    }

    // MARK: Events

    /// An engine action (ChatController.dispatch and the wake timer call it).
    func action(_ a: Action) {
        guard FlightRecorder.enabled, c != nil else { return }
        let name: String
        switch a {
        case .send: name = "send"; lastSend = CACurrentMediaTime()
        case let .status(id, s): name = "status \(id) \(s)"
        case let .receive(m): name = "receive \(m.id) from \(m.senderId)"
        case let .typing(who, on): name = "typing \(who) \(on)"
        case .setDraft: return
        // Paging and streaming carry whole messages: describing them formatted 200 messages per page (about 4 ms).
        case let .prependPage(p): name = "prependPage \(p.count)"
        case let .appendPage(p): name = "appendPage \(p.count)"
        case let .replaceWindow(p, start): name = "replaceWindow \(p.count) at \(start)"
        case let .appendText(id, t): name = "appendText \(id) +\(t.utf8.count)"
        default: name = String(String(describing: a).prefix(60))
        }
        event(name)
        kick()
    }

    func event(_ s: String) {
        events.append((CACurrentMediaTime(), s))
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }

    /// True while the display link samples (the self-test's idle check waits for it).
    var isSampling: Bool { link != nil }

    /// Something may animate: sample until it settles.
    func kick() {
        guard FlightRecorder.enabled, link == nil, let c else { return }
        let l = c.host.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    // MARK: Sampling

    @objc private func tick(_ l: CADisplayLink) {
        guard let c, let v = c.demo else { return }
        let now = CACurrentMediaTime()
        let s = sample(c, v, now)
        if ring.count < FlightRecorder.capacity { ring.append(s) } else { ring[ringStart] = s; ringStart = (ringStart + 1) % FlightRecorder.capacity }
        if now - lastSend < 10 { detect(s) }
        let busy = v.isAnimating || now - lastSend < 10 || pendingFinding != nil
        if !busy { l.invalidate(); link = nil }
    }

    private func sample(_ c: ChatController, _ v: MessagesWindowView, _ now: CFTimeInterval) -> Sample {
        let root = v.layer.presentation() ?? v.layer
        var rows: [Row] = []
        var seen = Set<String>()
        for case let cell as RowCell in v.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec else { continue }
            let p = cell.layer.presentation() ?? cell.layer
            let r = p.convert(p.bounds, to: root)
            let o = (cell.contentView.layer.presentation() ?? cell.contentView.layer).opacity
            let id = cell.bitmap.contents.map { ObjectIdentifier($0 as AnyObject).hashValue } ?? 0
            let age = (ages[spec.key] ?? 0) + 1
            seen.insert(spec.key)
            rows.append(Row(key: spec.key, rect: r, opacity: o, hasBitmap: cell.bitmap.contents != nil, bitmapID: id, age: age))
        }
        ages = ages.filter { seen.contains($0.key) }
        for r in rows { ages[r.key] = r.age }
        let morphs = v.morphs.map { (k, m) -> (String, CGRect) in
            let b = m.bubble.presentation() ?? m.bubble
            return (k, b.convert(b.bounds, to: root))
        }
        let screen = c.window?.screen  // cmux: the pane's window is optional
        return Sample(t: now, rows: rows, morphs: morphs, offset: v.collection.contentOffset.y, key: c.window?.isKeyWindow ?? false,
                      screen: screen?.localizedName ?? "?", hz: screen?.maximumFramesPerSecond ?? 0,
                      // cmux: FlashCheck is not vendored; its two presented-frame checks (HomeFlightRecorder).
                      gaps: HomeFlightRecorder.coverageGaps(v), unfilled: HomeFlightRecorder.unfilledOutgoing(v))
    }

    private var previous: Sample?
    private func detect(_ s: Sample) {
        defer { previous = s }
        guard let c, let v = c.demo else { return }
        var findings: [String] = []
        let morphKeys = Set(s.morphs.map(\.0))
        let top = Fixture.headerHeight, bottom = v.fieldTop
        for r in s.rows where r.age > 2 && !morphKeys.contains(r.key) && r.rect.maxY > top && r.rect.minY < bottom {
            guard let i = v.model.index[r.key], !v.model.rows[i].ghost else { continue }
            if !r.hasBitmap && r.opacity > 0.05 { findings.append("row \(r.key) has no bitmap") }
        }
        if let p = previous {
            let pr = Dictionary(p.rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let common = s.rows.filter { pr[$0.key] != nil && $0.age > 2 }
            let dys = common.map { $0.rect.minY - pr[$0.key]!.rect.minY }.sorted()
            let med = dys.isEmpty ? 0 : dys[dys.count / 2]
            for r in common where !morphKeys.contains(r.key) && !r.key.hasPrefix("typing") {
                let q = pr[r.key]!
                // An invisible row (a ghost fading out, a row under a hold)
                // moving differently shows nothing.
                if r.opacity > 0.05 || q.opacity > 0.05, abs((r.rect.minY - q.rect.minY) - med) > 12 { findings.append("row \(r.key) jumps \(Int(r.rect.minY - q.rect.minY - med)) pt") }
                if q.opacity > 0.98 && r.opacity < 0.5, let i = v.model.index[r.key], !v.model.rows[i].ghost {
                    findings.append("row \(r.key) opacity \(q.opacity) -> \(r.opacity)")
                }
            }
            // Gaps and unfilled bubbles: two samples in a row (one sample can
            // be read before that turn's layout pass).
            if !s.gaps.isEmpty && !p.gaps.isEmpty { findings.append("gap \(Int(s.gaps[0].0))-\(Int(s.gaps[0].1)) pt") }
            let both = Set(s.unfilled).intersection(p.unfilled)
            if !both.isEmpty { findings.append("unfilled \(both.first!)") }
        }
        guard let f = findings.first else { return }
        let now = CACurrentMediaTime()
        guard now - lastDump > 15 else { return }
        lastDump = now
        dump(reason: f + (findings.count > 1 ? " (+\(findings.count - 1) more)" : ""), all: findings)
    }

    // MARK: Dump

    /// Write the ring buffer, the events and a burst of window captures.
    @objc func saveLastSeconds(_ sender: Any?) { dump(reason: "Save Last 10 Seconds", all: []) }

    func dump(reason: String, all: [String]) {
        guard let c else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        // cmux: ~/Library/Logs/<app>/ (HomeFlightRecorder.logFolder), not MessagesLab's folder.
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/\(HomeFlightRecorder.logFolder)/blink-\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(atPath: dir + "/frames", withIntermediateDirectories: true)
        let samples = (0..<ring.count).map { ring[(ringStart + $0) % ring.count] }
        let t0 = samples.first?.t ?? CACurrentMediaTime()
        var lines: [String] = []
        for s in samples {
            let obj: [String: Any] = [
                "t": s.t - t0, "offset": Double(s.offset), "key": s.key, "screen": s.screen, "hz": s.hz,
                "rows": s.rows.map { [$0.key, Double($0.rect.minX), Double($0.rect.minY), Double($0.rect.width), Double($0.rect.height),
                                      Double($0.opacity), $0.hasBitmap ? 1 : 0, $0.bitmapID] as [Any] },
                "morphs": s.morphs.map { [$0.0, Double($0.1.minX), Double($0.1.minY), Double($0.1.width), Double($0.1.height)] as [Any] },
                "gaps": s.gaps.map { [Double($0.0), Double($0.1)] }, "unfilled": s.unfilled,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj), let l = String(data: d, encoding: .utf8) { lines.append(l) }
        }
        try? lines.joined(separator: "\n").write(toFile: dir + "/frames.ndjson", atomically: true, encoding: .utf8)
        // cmux: LiveProbes and Bench are not vendored (HomeFlightRecorder); the pane's window is optional.
        HomeFlightRecorder.writeJSON(["reason": reason, "findings": all, "events": events.map { ["t": $0.0 - t0, "event": $0.1] },
                          "window": ["key": c.window?.isKeyWindow ?? false, "screen": c.window?.screen?.localizedName ?? "?",
                                     "hz": c.window?.screen?.maximumFramesPerSecond ?? 0, "scale": c.window?.backingScaleFactor ?? 0,
                                     "frame": c.window.map { NSStringFromRect($0.frame) } ?? ""],
                          "load": HomeFlightRecorder.loadAverage, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""],
                         dir + "/meta.json")
        FileHandle.standardError.write("MessagesLab flight recorder: \(reason) -> \(dir)\n".data(using: .utf8)!)
        dumps.append(dir)
        // cmux: window captures only with their own opt-in (HomeFlightRecorder.capturesWindow).
        if HomeFlightRecorder.capturesWindow() { burst(dir, c, count: 30) }
    }

    /// About 0.5 s of window captures, one per display frame, off the main thread.
    private func burst(_ dir: String, _ c: ChatController, count: Int) {
        guard let window = c.window else { return }  // cmux: the pane's window is optional
        let wid = UInt32(window.windowNumber)
        let q = DispatchQueue(label: "flight.burst", qos: .utility)
        let start = CACurrentMediaTime()
        var i = 0
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60)
        timer.setEventHandler {
            let t = CACurrentMediaTime() - start
            // cmux: LiveRecord is not vendored (HomeFlightRecorder.grab, .writeJPEG).
            if let img = HomeFlightRecorder.grab(wid) { HomeFlightRecorder.writeJPEG(img, String(format: "%@/frames/burst_%02d_%.3f.jpg", dir, i, t)) }
            i += 1
            if i >= count { timer.cancel(); FlightRecorder.bursts.removeAll { $0 === timer } }
        }
        FlightRecorder.bursts.append(timer)
        timer.resume()
    }
}
