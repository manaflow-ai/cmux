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

    /// Raw per-frame storage, preallocated (no strings, dictionaries or allocation per
    /// frame; formatting happens only in `dump`). Rows are interned key ids.
    struct RawRow { var id: Int32 = 0; var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0; var opacity: Float = 0
                    var hasBitmap = false; var bitmapID = 0 }
    struct RawSample {
        var t: CFTimeInterval = 0; var offset: Float = 0; var key = false
        var rowCount = 0; var morphCount = 0
        var gap0: Float = 0, gap1: Float = 0, hasGap = false
        var unfilledID: Int32 = -1
        /// Display frames since the previous sample (the adaptive stride).
        var frames = 1
        /// The finding's numbers, rounded as its text prints them (the old rule compared texts).
        var unfilledSig = 0
    }
    static let maxRows = 64, maxMorphs = 4
    private static let capacity = 1300                       // ~10 s at 120 Hz
    private var samples = [RawSample](repeating: RawSample(), count: capacity)
    private var rows = [RawRow](repeating: RawRow(), count: capacity * maxRows)
    private var morphRows = [RawRow](repeating: RawRow(), count: capacity * maxMorphs)
    private var head = 0, filled = 0
    private var keyIDs: [String: Int32] = [:]
    private var keyNames: [String] = []
    /// Per key id: consecutive samples seen, the frame last seen, last presented y and opacity.
    private var age: [Int32] = [], lastFrame: [Int] = [], lastY: [Float] = [], lastOpacity: [Float] = []
    private var frameNo = 0
    private var screenName = "?", screenHz = 0
    private var dys: [Float] = []
    private var spans: [(Float, Float)] = []
    private var unfilledText: [Int32: String] = [:]
    private var events: [(CFTimeInterval, String)] = []
    private weak var c: ChatController?
    private var link: CADisplayLink?
    private var lastSend: CFTimeInterval = -.infinity
    private var lastDump: CFTimeInterval = -.infinity
    private var pendingFinding: (CFTimeInterval, String)?
    private(set) var dumps: [String] = []
    private static var bursts: [DispatchSourceTimer] = []
    private static let dumpQueue = DispatchQueue(label: "flight.dump", qos: .utility)

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

    /// Main-thread cost of each tick (bench evidence; target 0.3 ms or less).
    static var tickCount = 0, tickMsTotal = 0.0, tickMsMax = 0.0, ticksOver03 = 0, framesSkipped = 0
    static var modelChecks = 0, modelCheckMsMax = 0.0
    static var slowTicks: [[String: Double]] = []
    /// Adaptive stride: every frame while a sample costs under 0.2 ms; every 2nd-4th frame
    /// while presented geometry is expensive (many cells, each with many additive springs
    /// during fast sends: presentation() applies them all). Target 0.3 ms per frame.
    private var stride = 1, skip = 0
    @objc private func tick(_ l: CADisplayLink) {
        guard let c, let v = c.demo else { return }
        let now = CACurrentMediaTime()
        if skip > 0 {
            skip -= 1
            // Frames between samples: model facts only (no presentation reads), so a one-frame
            // blink of a row (hidden, opacity 0, no contents) is never missed.
            let m0 = CACurrentMediaTime()
            if now - lastSend < 10 { modelCheck(v) }
            FlightRecorder.modelChecks += 1
            FlightRecorder.modelCheckMsMax = max(FlightRecorder.modelCheckMsMax, (CACurrentMediaTime() - m0) * 1000)
            if !(v.isAnimating || now - lastSend < 10 || pendingFinding != nil) { l.invalidate(); link = nil }
            return
        }
        defer {
            let ms = (CACurrentMediaTime() - now) * 1000
            FlightRecorder.tickCount += 1; FlightRecorder.tickMsTotal += ms; FlightRecorder.tickMsMax = max(FlightRecorder.tickMsMax, ms)
            if ms > 0.3 { FlightRecorder.ticksOver03 += 1 }
            if ms > 0.3 { stride = min(4, stride + 1) } else if ms < 0.2 { stride = max(1, stride - 1) }
            skip = stride - 1
            FlightRecorder.framesSkipped += skip
        }
        let slot = head
        sample(c, v, now, into: slot)
        let t1 = CACurrentMediaTime()
        samples[slot].frames = stride
        head = (head + 1) % FlightRecorder.capacity
        filled = min(filled + 1, FlightRecorder.capacity)
        if now - lastSend < 10 { detect(slot, v) }
        let t2 = CACurrentMediaTime()
        updateAges(slot)
        let t3 = CACurrentMediaTime()
        // A slow tick (above 2 ms): its phases, for the bench.
        if t3 - now > 0.002 {
            FlightRecorder.slowTicks.append(["sampleMs": (t1 - now) * 1000, "detectMs": (t2 - t1) * 1000, "agesMs": (t3 - t2) * 1000,
                                             "rows": Double(samples[slot].rowCount), "keys": Double(keyNames.count),
                                             "morphs": Double(samples[slot].morphCount), "dumped": now - lastDump < 0.01 ? 1 : 0])
            if FlightRecorder.slowTicks.count > 8 { FlightRecorder.slowTicks.removeFirst() }
        }
        let busy = v.isAnimating || now - lastSend < 10 || pendingFinding != nil
        if !busy { l.invalidate(); link = nil }
    }

    private func intern(_ key: String) -> Int32 {
        if let id = keyIDs[key] { return id }
        let id = Int32(keyNames.count)
        keyIDs[key] = id; keyNames.append(key)
        age.append(0); lastFrame.append(-2); lastY.append(0); lastOpacity.append(0)
        return id
    }

    /// Presented geometry without `presentation()` copies for layers that do not animate,
    /// and without `convert(_:to:)`: a cell's window y is its presented position in the
    /// list minus the list's presented scroll offset plus the list's origin in the window.
    private func sample(_ c: ChatController, _ v: MessagesWindowView, _ now: CFTimeInterval, into slot: Int) {
        frameNo += 1
        let list = v.collection.layer
        let listOrigin = list.superlayer == nil ? CGPoint.zero : list.convert(CGPoint.zero, to: v.layer)
        // Container motion: the transcript's sublayer transform moves every row (WindowView.animateRows),
        // one additive spring per send; its closed form when those are the only animations.
        let originY: Float
        if let keys = list.animationKeys(), FlightRecorder.presentationReads
            || keys.contains(where: { !($0.hasPrefix("spring.sublayerTransform.translation.y.") || $0.hasPrefix("sampled.sublayerTransform.translation.y.")) }) {
            let lp = list.presentation() ?? list
            originY = Float(listOrigin.y + list.bounds.minY - lp.bounds.minY + lp.sublayerTransform.m42)
        } else {
            originY = Float(Double(listOrigin.y + list.sublayerTransform.m42) + v.containerTranslation(at: Animate.now(v.layer)))
            if FlightRecorder.verifyMath, MessagesWindowView.commitLog?.isEmpty ?? true, let lp = list.presentation() {
                let d = abs(Double(originY) - Double(listOrigin.y + list.bounds.minY - lp.bounds.minY + lp.sublayerTransform.m42))
                if d > FlightRecorder.verifyMax { FlightRecorder.verifyMax = d; FlightRecorder.verifyWorst = "container \(d)" }
            }
        }
        var s = RawSample(t: now, offset: Float(v.collection.contentOffset.y), key: c.window?.isKeyWindow ?? false)  // cmux: optional window
        let base = slot * FlightRecorder.maxRows
        var n = 0
        // Coverage gaps from the same rows (FlashCheck.coverageGaps rules), unfilled outgoing bubbles.
        let top = Float(Fixture.headerHeight), bottom = Float(v.fieldTop - 4)
        let firstKey = v.store.state.windowStart == 0 ? v.model.rows.first?.spec.key : nil
        var coverStart = top
        spans.removeAll(keepingCapacity: true)
        let lnow = Animate.now(v.layer)
        for case let cell as RowCell in v.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, n < FlightRecorder.maxRows else { continue }
            let entries = v.ledger.live(spec.key)
            if FlightRecorder.verifyMath {
                let ip = v.collection.indexPath(for: cell)?.item
                let mk = ip.flatMap { $0 < v.model.count ? v.model.rows[$0].spec.key : nil } ?? "-"
                FlightRecorder.verifyKey = "\(spec.key) cellKey \(cell.key) cell \(ObjectIdentifier(cell).hashValue % 100000) ip \(ip ?? -1) modelKeyAtIp \(mk) modelIndex \(v.model.index[spec.key] ?? -1) frameY \(cell.frame.minY)"
                if spec.key != mk || cell.key != spec.key, FlightRecorder.verifyLog.count < 24 { FlightRecorder.verifyLog.append("MISMATCH " + FlightRecorder.verifyKey) }
            }
            let cl = cell.layer
            let cellPY = presented(cl, "position.y", .cell, entries, cell.applied, lnow)
            // x: no ledger motion moves a row sideways; any other animation reads the presentation.
            let px = cl.animationKeys() == nil || cellPY != nil ? cl.position.x : (cl.presentation() ?? cl).position.x
            let y = originY + Float((cellPY ?? Double((cl.presentation() ?? cl).position.y)) - cl.bounds.height * cl.anchorPoint.y)
            let x = Float(listOrigin.x + px - cl.bounds.width * cl.anchorPoint.x)
            let content = cell.contentView.layer
            let op = Float(presented(content, "opacity", .content, entries, cell.applied, lnow) ?? Double((content.presentation() ?? content).opacity))
            let id = intern(spec.key)
            let hasBitmap = cell.bitmap.contents != nil
            rows[base + n] = RawRow(id: id, x: x, y: y, w: Float(cl.bounds.width), h: Float(cl.bounds.height), opacity: op,
                                    hasBitmap: hasBitmap, bitmapID: cell.bitmap.contents.map { ObjectIdentifier($0 as AnyObject).hashValue } ?? 0)
            n += 1
            spans.append((y, y + Float(cl.bounds.height)))
            if let firstKey, spec.key == firstKey { coverStart = max(top, y) }
            if s.unfilledID < 0, !cell.fillContainer.isHidden, case .part = spec.kind, RowDraw.needsFill(spec) {
                let body = RowDraw.bodyRect(spec)
                let by0 = y + Float(body.minY), by1 = y + Float(body.maxY)
                if by1 > top, by0 < Float(v.fieldTop) {
                    // The gradient sits in the content layer (which animates during a send) and the
                    // fill container: their presented origins count, as convert(_:to:) counted them.
                    let g = cell.fillGradient
                    var chain = y
                    for l in [content, cell.fillContainer] {
                        // No ledger target moves these two (the content layer only fades).
                        let ly = presented(l, "position.y", nil, entries, cell.applied, lnow) ?? Double((l.presentation() ?? l).position.y)
                        chain += Float(ly - l.bounds.height * l.anchorPoint.y - l.bounds.minY)
                    }
                    let gpy = presented(g, "position.y", .fillGradient, entries, cell.applied, lnow) ?? Double((g.presentation() ?? g).position.y)
                    let gy0 = chain + Float(gpy - g.bounds.height * g.anchorPoint.y), gy1 = gy0 + Float(g.bounds.height)
                    if by0 < gy0 - 0.5 || by1 > gy1 + 0.5 {
                        s.unfilledID = id
                        var h = Hasher(); h.combine(id); h.combine(Int(by0)); h.combine(Int(by1)); h.combine(Int(gy0)); h.combine(Int(gy1))
                        s.unfilledSig = h.finalize()
                        unfilledText[id] = "\(spec.key) body \(Int(by0))-\(Int(by1)) fill \(Int(gy0))-\(Int(gy1))"
                    }
                }
            }
        }
        s.rowCount = n
        spans.sort { $0.0 < $1.0 }
        var yy = coverStart
        if !(v.store.state.windowStart == 0 && v.model.count == 0) {
            for (a, b) in spans where b > yy {
                if a - yy > 40, a > top, !s.hasGap { s.hasGap = true; s.gap0 = yy; s.gap1 = min(a, bottom) }
                yy = max(yy, b)
                if yy >= bottom { break }
            }
            if bottom - yy > 40, !s.hasGap { s.hasGap = true; s.gap0 = yy; s.gap1 = bottom }
        }
        var m = 0
        let mbase = slot * FlightRecorder.maxMorphs
        for (k, mb) in v.morphs where m < FlightRecorder.maxMorphs {
            // The detector needs the ids; the dump keeps the model rect (a presentation of the
            // root view cost up to 8 ms with 4 morphs in flight).
            let b = mb.bubble
            let r = b.convert(b.bounds, to: v.layer)
            morphRows[mbase + m] = RawRow(id: intern(k), x: Float(r.minX), y: Float(r.minY), w: Float(r.width), h: Float(r.height))
            m += 1
        }
        s.morphCount = m
        samples[slot] = s
    }

    /// A layer's presented value of `keyPath` from its model value plus the motion ledger's
    /// springs already applied to it (WindowView.decorate adds each entry once, additively, from
    /// `from - to` to 0; a hold overrides until its end), the same closed form the render server
    /// runs: no `presentation()` copy, whose cost grew with the number of live springs (2-8 ms per
    /// sample with 50 rows during fast sends). Nil when the layer carries an animation the ledger
    /// did not make (swipe, typing, AppKit): the caller reads the presentation then.
    /// `--recorder-presentation`: always nil (the old reads, A/B).
    static let presentationReads = ProcessInfo.processInfo.arguments.contains("--recorder-presentation")
    private func presented(_ l: CALayer, _ keyPath: String, _ target: MotionLedger.Target?, _ entries: [MotionLedger.Entry],
                           _ applied: AppliedEntries, _ now: CFTimeInterval) -> Double? {
        let model = Double(keyPath == "opacity" ? CGFloat(l.opacity) : l.position.y)
        guard let keys = l.animationKeys() else { return model }
        guard !FlightRecorder.presentationReads else { return nil }
        for k in keys where !(k.hasPrefix("spring.") || k.hasPrefix("sampled.") || k.hasPrefix("curve.") || k.hasPrefix("hold.")) { return nil }
        var v = model, hold: Double?
        for e in entries where e.target == target && e.keyPath == keyPath && applied.contains(e.id) && now < e.end {
            if let h = e.hold { if now >= e.begin { hold = h }; continue }
            v += e.element.value(now - e.begin, from: e.from, to: e.to) - e.to
        }
        let out = hold ?? v
        if FlightRecorder.verifyMath, let p = l.presentation() {
            // `--recorder-verify` (bench evidence): the closed form against Core Animation's own value.
            let pv = Double(keyPath == "opacity" ? CGFloat(p.opacity) : p.position.y)
            let d = abs(pv - out) / (keyPath == "opacity" ? 0.01 : 1)
            // Only ticks with no transaction earlier in the same run-loop pass: otherwise the model
            // holds changes that the presentation (last commit) does not show yet.
            let lid = ObjectIdentifier(l).hashValue &+ keyPath.count
            let movedModel = FlightRecorder.verifyLastModel[lid].map { $0 != model } ?? true
            FlightRecorder.verifyLastModel[lid] = model
            guard MessagesWindowView.commitLog?.isEmpty ?? true, !movedModel else { FlightRecorder.verifySkipped += 1; return out }
            FlightRecorder.verifyCount += 1
            if d > 0.5 { FlightRecorder.verifyOver += 1 }
            if d > FlightRecorder.verifyMax { FlightRecorder.verifyMax = d; FlightRecorder.verifyWorst = "\(keyPath) model \(model) math \(out) ca \(pv)" }
            if d > 0.5, FlightRecorder.verifyLog.count < 16 {
                // The layer's animations on this key path and the ledger's view of them (cause hunt).
                func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
                let es = entries.filter { $0.keyPath == keyPath }.map {
                    "#\($0.id) \($0.target) from \(r($0.from)) b \(r($0.begin - now)) e \(r($0.end - now)) \(applied.contains($0.id) ? "A" : "-")\($0.hold != nil ? " hold" : "")"
                }
                let anims = keys.compactMap { k -> String? in
                    guard let a = l.animation(forKey: k) as? CAPropertyAnimation, a.keyPath == keyPath else { return nil }
                    let from = (a as? CABasicAnimation)?.fromValue ?? (a as? CAKeyframeAnimation)?.values?.first
                    return "\(k) b \(r(a.beginTime - now)) dur \(r(a.duration)) from \(from ?? "?")"
                }
                FlightRecorder.verifyLog.append("\(FlightRecorder.verifyKey) \(target.map { "\($0)" } ?? "nil") \(keyPath) d \(r(d)) model \(r(model)) math \(r(out)) ca \(r(pv)) applied \(applied.sorted()) entries \(es) anims \(anims)")
            }
        }
        return out
    }
    static let verifyMath = ProcessInfo.processInfo.arguments.contains("--recorder-verify")
    /// Largest difference (points; opacity in hundredths) and its values.
    static var verifyMax = 0.0, verifyCount = 0, verifyWorst = "", verifyOver = 0, verifySkipped = 0
    static var verifyLastModel: [Int: Double] = [:]
    static var verifyKey = "", verifyLog: [String] = []

    private var previousSlot = -1
    /// Ages and last positions for the next frame (every frame, detector or not).
    private func updateAges(_ slot: Int) {
        let base = slot * FlightRecorder.maxRows
        for i in 0..<samples[slot].rowCount {
            let r = rows[base + i], id = Int(r.id)
            age[id] = lastFrame[id] == frameNo - 1 ? age[id] + 1 : 1
            lastFrame[id] = frameNo; lastY[id] = r.y; lastOpacity[id] = r.opacity
        }
        previousSlot = slot
    }

    /// Model facts of the visible rows (no presentation): a row on screen that is hidden, has
    /// a model opacity of 0 while its row is live and not under a send's hold, or has no
    /// contents. Rows seen in the previous sample (age > 2) only, as `detect` does.
    private func modelCheck(_ v: MessagesWindowView) {
        let top = Fixture.headerHeight, bottom = v.fieldTop, b = v.collection.bounds
        let originY = v.collection.frame.minY
        for case let cell as RowCell in v.collection.visibleCells {
            guard let spec = cell.spec, let id = keyIDs[spec.key], age[Int(id)] > 2 else { continue }
            let y = originY + cell.frame.minY - b.minY
            guard y + cell.frame.height > top, y < bottom, v.morphs[spec.key] == nil else { continue }
            guard let i = v.model.index[spec.key], !v.model.rows[i].ghost else { continue }
            var f: String?
            if cell.isHidden { f = "row \(spec.key) hidden (model)" }
            else if cell.bitmap.contents == nil, cell.tiled?.isActive != true, !RowCell.deferredKeys.contains(spec.key) { f = "row \(spec.key) has no bitmap (model)" }
            else if cell.contentView.layer.opacity < 0.05, cell.contentView.layer.animationKeys() == nil { f = "row \(spec.key) opacity 0 (model)" }
            guard let f, CACurrentMediaTime() - lastDump > 15 else { continue }
            lastDump = CACurrentMediaTime()
            dump(reason: f, all: [f])
            return
        }
    }

    private func detect(_ slot: Int, _ v: MessagesWindowView) {
        let s = samples[slot], base = slot * FlightRecorder.maxRows
        var findings: [String] = []
        let top = Float(Fixture.headerHeight), bottom = Float(v.fieldTop)
        func isMorph(_ id: Int32) -> Bool {
            let mb = slot * FlightRecorder.maxMorphs
            for k in 0..<s.morphCount where morphRows[mb + k].id == id { return true }
            return false
        }
        func liveRow(_ id: Int32) -> Bool {
            guard let i = v.model.index[keyNames[Int(id)]] else { return false }
            return !v.model.rows[i].ghost
        }
        // Age as of this frame (the stored age is from the previous frame).
        func ageNow(_ id: Int) -> Int32 { lastFrame[id] == frameNo - 1 ? age[id] + 1 : 1 }
        for i in 0..<s.rowCount {
            let r = rows[base + i]
            guard ageNow(Int(r.id)) > 2, !isMorph(r.id), r.y + r.h > top, r.y < bottom else { continue }
            if !r.hasBitmap && r.opacity > 0.05 && liveRow(r.id) { findings.append("row \(keyNames[Int(r.id)]) has no bitmap") }
        }
        if previousSlot >= 0, samples[previousSlot].t > 0 {
            let p = samples[previousSlot]
            dys.removeAll(keepingCapacity: true)
            for i in 0..<s.rowCount {
                let r = rows[base + i], id = Int(r.id)
                if lastFrame[id] == frameNo - 1, ageNow(id) > 2 { dys.append(r.y - lastY[id]) }
            }
            dys.sort()
            let med = dys.isEmpty ? 0 : dys[dys.count / 2]
            for i in 0..<s.rowCount {
                let r = rows[base + i], id = Int(r.id)
                guard lastFrame[id] == frameNo - 1, ageNow(id) > 2, !isMorph(r.id), !keyNames[id].hasPrefix("typing") else { continue }
                // An invisible row (a ghost fading out, a row under a hold) moving differently shows nothing.
                // 12 pt per display frame between samples (the stride spreads a sample's motion).
                if r.opacity > 0.05 || lastOpacity[id] > 0.05, abs((r.y - lastY[id]) - med) > 12 * Float(s.frames) {
                    findings.append("row \(keyNames[id]) jumps \(Int(r.y - lastY[id] - med)) pt")
                }
                if lastOpacity[id] > 0.98 && r.opacity < 0.5, liveRow(r.id) {
                    findings.append("row \(keyNames[id]) opacity \(lastOpacity[id]) -> \(r.opacity)")
                }
            }
            // Gaps and unfilled bubbles: two samples in a row (one sample can be read before
            // that turn's layout pass).
            if s.hasGap && p.hasGap { findings.append("gap \(Int(s.gap0))-\(Int(s.gap1)) pt") }
            if s.unfilledID >= 0, s.unfilledID == p.unfilledID, s.unfilledSig == p.unfilledSig { findings.append("unfilled \(unfilledText[s.unfilledID] ?? "")") }
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
        screenName = c.window?.screen?.localizedName ?? "?"  // cmux: the pane's window is optional
        screenHz = c.window?.screen?.maximumFramesPerSecond ?? 0
        let order = (0..<filled).map { (head - filled + $0 + FlightRecorder.capacity) % FlightRecorder.capacity }
        let t0 = order.first.map { self.samples[$0].t } ?? CACurrentMediaTime()
        // Formatting and writing run off main on copies of the raw arrays (a dump cost 8-9 ms on main).
        let (samples, rows, morphRows, keyNames, unfilledText, screenName, screenHz) =
            (self.samples, self.rows, self.morphRows, self.keyNames, self.unfilledText, self.screenName, self.screenHz)
        FlightRecorder.dumpQueue.async {
        var lines: [String] = []
        for slot in order {
            let s = samples[slot], base = slot * FlightRecorder.maxRows, mbase = slot * FlightRecorder.maxMorphs
            let obj: [String: Any] = [
                "t": s.t - t0, "offset": Double(s.offset), "key": s.key, "screen": screenName, "hz": screenHz,
                "rows": (0..<s.rowCount).map { i -> [Any] in
                    let r = rows[base + i]
                    return [keyNames[Int(r.id)], Double(r.x), Double(r.y), Double(r.w), Double(r.h), Double(r.opacity), r.hasBitmap ? 1 : 0, r.bitmapID]
                },
                "morphs": (0..<s.morphCount).map { i -> [Any] in
                    let r = morphRows[mbase + i]
                    return [keyNames[Int(r.id)], Double(r.x), Double(r.y), Double(r.w), Double(r.h)]
                },
                "gaps": s.hasGap ? [[Double(s.gap0), Double(s.gap1)]] : [],
                "unfilled": s.unfilledID >= 0 ? [unfilledText[s.unfilledID] ?? ""] : [],
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj), let l = String(data: d, encoding: .utf8) { lines.append(l) }
        }
        try? lines.joined(separator: "\n").write(toFile: dir + "/frames.ndjson", atomically: true, encoding: .utf8)
        }
        // cmux: LiveProbes and Bench are not vendored (HomeFlightRecorder); the pane's window is optional.
        HomeFlightRecorder.writeJSON(["reason": reason, "findings": all, "events": events.map { ["t": $0.0 - t0, "event": $0.1] },
                          "window": ["key": c.window?.isKeyWindow ?? false, "screen": c.window?.screen?.localizedName ?? "?",
                                     "hz": c.window?.screen?.maximumFramesPerSecond ?? 0, "scale": c.window?.backingScaleFactor ?? 0,
                                     "frame": c.window.map { NSStringFromRect($0.frame) } ?? ""],
                          "load": HomeFlightRecorder.loadAverage, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""],
                         dir + "/meta.json")
        FileHandle.standardError.write(Data("MessagesLab flight recorder: \(reason) -> \(dir)\n".utf8)) // cmux: no force unwrap
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
