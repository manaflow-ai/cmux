#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import UniformTypeIdentifiers

/// The differential harness, compiled into catalyst/ and appkit-port/ (same
/// source). `--diff-harness OUT` runs one scripted conversation on a virtual
/// clock in an offscreen window view and writes, for every 120 Hz tick, the
/// presented layer tree (closed-form evaluation of the animations each app
/// committed, `Presenter`), and PNG captures at fixed times. The script, the
/// store and the window view are identical; only the platform layer differs
/// (UIKit on Catalyst; the AppKit shim, NSTextView and Core Animation hosting
/// in appkit-port). tools/diff-harness/diff.py compares two runs.
///
/// Layer names are stable across apps: `row[<row key>]/<role>` for transcript
/// rows (cell, content, fill, bitmap, connector, connectorLine, typing, dot0-2,
/// receiptOld), `morph[<row key>]/<role>` for the send morph, `compose/...`,
/// `header/...`, `chrome`, `clipMask`, `window/<index>` for the rest, and
/// `<name>/<index>` for unnamed sublayers.
enum DiffHarness {
    struct Event { var t: Double; var name: String; var duration: Double }

    /// The scripted conversation (virtual seconds). Transitions are named for
    /// the report.
    static let transitions: [Event] = [
        Event(t: 0.50, name: "send (2 lines, morph)", duration: 1.0),
        Event(t: 1.60, name: "delivered", duration: 0.9),
        Event(t: 2.60, name: "delivered -> read", duration: 0.6),
        Event(t: 3.20, name: "typing indicator", duration: 1.0),
        Event(t: 4.40, name: "thread reply arrives", duration: 1.1),
        Event(t: 5.62, name: "double send (140 ms apart)", duration: 1.5),
        Event(t: 7.20, name: "received message", duration: 1.1),
        Event(t: 8.40, name: "thread reply to an older root (preview)", duration: 1.1),
        Event(t: 9.60, name: "scroll fling (scripted offsets)", duration: 1.2),
        Event(t: 11.00, name: "jump to oldest", duration: 0.5),
        Event(t: 11.60, name: "jump to newest", duration: 0.7),
    ]
    static let end = 12.4
    static let them = "instinct"

    static func makeStore() -> Store {
        let store = Store(conversation: Fixtures.loadConversation(), baseDate: Replay.base)
        store.responder = nil
        store.schedule(.setDraft("How are you doing?\nSome multiline text..."), at: 0.10)
        store.schedule(.send, at: 0.50)
        var sent: ID?
        store.scheduleStep(at: 0.501) { s in
            sent = s.state.conversation.messages.last?.id
            if let id = sent { s.dispatch(.status(id, .sent)) }
        }
        store.scheduleStep(at: 1.60) { s in if let id = sent { s.dispatch(.status(id, .delivered(at: Instant.format(s.date(at: 1.6))))) } }
        store.scheduleStep(at: 2.60) { s in if let id = sent { s.dispatch(.status(id, .read(at: Instant.format(s.date(at: 2.6))))) } }
        store.schedule(.typing(them, true), at: 3.20)
        store.scheduleStep(at: 4.40) { s in
            guard let id = sent else { return }
            s.dispatch(.receive(message("h-reply", 4.4, "Doing well, and the multiline renders nicely. Anything you want me to do with it?",
                                        replyTo: PartRef(messageId: id, partIndex: 0), s)))
        }
        store.schedule(.setDraft("Second one"), at: 5.55)
        store.schedule(.send, at: 5.62)
        store.schedule(.setDraft("Third one, right after"), at: 5.70)
        store.schedule(.send, at: 5.76)
        store.scheduleStep(at: 7.20) { s in s.dispatch(.receive(message("h-plain", 7.2, "Got both.", replyTo: nil, s))) }
        store.scheduleStep(at: 8.40) { s in
            let root = s.state.conversation.messages.first { $0.senderId != s.state.me && $0.replyTo == nil && $0.parts.first?.plainText != nil }
            s.dispatch(.receive(message("h-preview", 8.4, "Replying to that earlier one.",
                                        replyTo: root.map { PartRef(messageId: $0.id, partIndex: 0) }, s)))
        }
        return store
    }

    static func message(_ id: ID, _ t: Double, _ text: String, replyTo: PartRef?, _ s: Store) -> Message {
        Message(id: id, senderId: them, sentAt: Instant.format(s.date(at: t)), parts: [.text(text, runs: [])],
                replyTo: replyTo, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    /// Scripted scroll: a fling of 2,500 pt up with an exponential tail,
    /// applied to the transcript's offset at each tick (the same offsets in
    /// both apps; the physics are compared separately by the scroll trace).
    static func scriptedOffset(_ t: Double, start: CGFloat) -> CGFloat? {
        let t0 = 9.6
        guard t >= t0, t <= t0 + 1.2 else { return nil }
        return start - CGFloat(2500 * (1 - exp(-(t - t0) / 0.25)))
    }

    static func captureTimes() -> [Double] {
        var out: [Double] = [0.4]
        for e in transitions {
            for dt in [-0.017, 0.017, 0.042, 0.083, 0.125, 0.167, 0.25, 0.333, 0.5, 0.75, 1.0] where dt < e.duration {
                out.append(((e.t + dt) * 120).rounded() / 120)
            }
        }
        return Array(Set(out)).sorted()
    }

    // MARK: Run

    static func runOffscreen(outDir: String, arguments: [String]) {
        try? FileManager.default.createDirectory(atPath: outDir + "/png", withIntermediateDirectories: true)
        #if !canImport(UIKit)
        // Test renders keep the reference's 2x (Catalyst's screen scale here).
        DisplayScale.current = 2
        #endif
        Fixture.renderScale = 2
        let store = makeStore()
        var vt = 0.0
        let view = MessagesWindowView(store: store)
        view.clock = { vt }
        view.captureMode = true
        #if !canImport(UIKit)
        view.layer.isGeometryFlipped = true
        #endif
        view.layer.speed = 0
        if ProcessInfo.processInfo.environment["ML_HARNESS_DEBUG"] != nil {
            let cells = view.collection.visibleCells.compactMap { $0 as? RowCell }
            print("harness init: offset \(view.collection.contentOffset.y) size \(view.collection.contentSize.height) cells \(cells.count) with contents \(cells.filter { $0.bitmap.contents != nil }.count)")
        }
        let captures = Set(captureTimes().map { Int(($0 * 120).rounded()) })
        let skipPixels = arguments.contains("--no-pixels")
        var lines: [String] = []
        var animLines: [String] = []
        var flingStart: CGFloat?
        let ticks = Int(end * 120)
        for k in 0...ticks {
            let t = Double(k) / 120
            vt = t
            view.layer.timeOffset = t
            store.advance(to: t)
            if t >= 11.0, t - 1.0 / 120 < 11.0 { view.show(seqIndex: 0) }
            if t >= 11.6, t - 1.0 / 120 < 11.6 { view.pinToBottom() }
            if flingStart == nil, t >= 9.6 { flingStart = view.collection.contentOffset.y }
            if let s = flingStart, let y = scriptedOffset(t, start: s) {
                let cv = view.collection
                cv.contentOffset.y = max(view.minOffset, min(view.pinnedOffset, y))
                view.userScrolled()
            }
            view.prepareCapture(at: t)
            view.layoutIfNeeded()
            view.collection.layoutIfNeeded()
            view.layer.displayRecursively()
            if transitions.contains(where: { Int(($0.t * 120).rounded()) + 2 == k }) {
                animLines.append(animationsJSON(t, view))
            }
            let saved = Presenter.apply(view.layer)
            let tree = dump(view)
            lines.append(frameJSON(t, tree))
            if !skipPixels, captures.contains(k) {
                view.header.refresh()
                writePNG(render(view), String(format: "%@/png/t_%05d.png", outDir, Int((t * 1000).rounded())))
            }
            Presenter.restore(saved)
        }
        let meta: [String: Any] = [
            "app": appName, "end": end, "hz": 120,
            "transitions": transitions.map { ["t": $0.t, "name": $0.name, "duration": $0.duration] },
            "captures": captureTimes(),
            "symbols": symbolSizes(),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: outDir + "/meta.json"))
        }
        try? lines.joined(separator: "\n").write(toFile: outDir + "/frames.ndjson", atomically: true, encoding: .utf8)
        try? animLines.joined(separator: "\n").write(toFile: outDir + "/animations.ndjson", atomically: true, encoding: .utf8)
    }

    #if canImport(UIKit)
    static let appName = "catalyst"
    #elseif APPKIT_NATIVE
    static let appName = "appkit-native"
    #else
    static let appName = "appkit-port"
    #endif

    // MARK: Layer tree

    struct Element { var name: String; var values: [Double] }

    /// Field order of each element in frames.ndjson.
    static let fields = ["x", "y", "w", "h", "opacity", "a", "b", "c", "d", "tx", "ty", "cornerRadius",
                         "contentsScale", "contentsPxW", "contentsPxH", "hidden"]

    static func dump(_ view: MessagesWindowView) -> [Element] {
        var names: [ObjectIdentifier: String] = [:]
        var skipChildren = Set<ObjectIdentifier>()
        func name(_ l: CALayer?, _ n: String) { if let l { names[ObjectIdentifier(l)] = n } }
        for case let cell as RowCell in view.collection.visibleCells {
            guard let key = cell.spec?.key, !cell.isHidden else { continue }
            let p = "row[\(key)]"
            name(cell.layer, p + "/cell")
            name(cell.contentView.layer, p + "/content")
            name(cell.fillContainer, p + "/fill")
            name(cell.fillGradient, p + "/fillGradient")
            name(cell.fillMask, p + "/fillMask")
            name(cell.bitmap, p + "/bitmap")
            name(cell.connector, p + "/connector")
            name(cell.connectorLine, p + "/connectorLine")
            name(cell.typingContainer, p + "/typing")
            name(cell.receiptOld, p + "/receiptOld")
            for (i, d) in cell.dots.enumerated() { name(d, p + "/dot\(i)"); name(d.sublayers?.first, p + "/dot\(i)/hi") }
        }
        for (key, m) in view.morphs {
            let p = "morph[\(key)]"
            name(m.holder, p + "/holder"); name(m.bubble, p + "/bubble"); name(m.body, p + "/body"); name(m.text, p + "/text")
            name(m.blurred, p + "/blurred"); name(m.tail, p + "/tail"); name(m.underlay, p + "/underlay")
        }
        name(view.collection.layer, "transcript")
        name(view.clipMask, "clipMask")
        name(view.header.layer, "header")
        name(view.compose.layer, "compose")
        name(view.compose.glass, "compose/glass")
        name(view.compose.caret, "compose/caret")
        #if canImport(UIKit)
        let textLayer = view.compose.textView.layer
        #else
        let textLayer = view.compose.textSnapshot
        #endif
        name(textLayer, "compose/text")
        skipChildren.insert(ObjectIdentifier(textLayer))
        name(view.chrome.layer, "chrome")
        name(view.morphView.layer, "morphs")
        // UIKit-internal sublayers of the transcript scroll view (scroll
        // indicators) have no AppKit counterpart.
        var out: [Element] = []
        let root = view.layer
        func visit(_ l: CALayer, _ path: String) {
            let id = ObjectIdentifier(l)
            let n = names[id] ?? path
            if l.isHidden { out.append(Element(name: n, values: values(l, root, hidden: true))); return }
            out.append(Element(name: n, values: values(l, root, hidden: false)))
            if let m = l.mask { visit(m, n + "/mask") }
            guard !skipChildren.contains(id) else { return }
            for (i, s) in (l.sublayers ?? []).enumerated() {
                // Unnamed layers directly in the transcript are pool cells or
                // UIKit's scroll indicators: skip them.
                if n == "transcript", names[ObjectIdentifier(s)] == nil { continue }
                visit(s, n + "/\(i)")
            }
        }
        for (i, s) in (root.sublayers ?? []).enumerated() { visit(s, "window/\(i)") }
        return out
    }

    static func values(_ l: CALayer, _ root: CALayer, hidden: Bool) -> [Double] {
        let f = l.convert(l.bounds, to: root)
        let t = CATransform3DGetAffineTransform(l.transform)
        var pxW = 0.0, pxH = 0.0
        if let c = l.contents {
            let cf = c as CFTypeRef
            if CFGetTypeID(cf) == CGImage.typeID {
                let img = c as! CGImage
                pxW = Double(img.width); pxH = Double(img.height)
            }
        }
        return [f.minX, f.minY, f.width, f.height, Double(l.opacity), t.a, t.b, t.c, t.d, t.tx, t.ty, l.cornerRadius,
                l.contentsScale, pxW, pxH, hidden ? 1 : 0].map { Double($0) }
    }

    static func frameJSON(_ t: Double, _ elements: [Element]) -> String {
        var s = "{\"t\":\(String(format: "%.5f", t)),\"L\":{"
        var first = true
        for e in elements {
            if !first { s += "," }
            first = false
            let esc = e.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            s += "\"\(esc)\":[" + e.values.map { $0.isFinite ? String(format: "%.4f", $0) : "0" }.joined(separator: ",") + "]"
        }
        return s + "}}"
    }

    /// Every animation on the named layers, as committed (one line per
    /// transition, two ticks after it starts): key path, kind, begin time,
    /// duration, from/to, spring constants, additive flag. Keys are sorted by
    /// (key path, begin, from) so equal transactions compare equal.
    static func animationsJSON(_ t: Double, _ view: MessagesWindowView) -> String {
        var out: [String: [[String: Any]]] = [:]
        var layers: [(String, CALayer)] = []
        for case let cell as RowCell in view.collection.visibleCells {
            guard let key = cell.spec?.key, !cell.isHidden else { continue }
            let p = "row[\(key)]"
            layers += [(p + "/cell", cell.layer), (p + "/content", cell.contentView.layer), (p + "/bitmap", cell.bitmap),
                       (p + "/connector", cell.connector), (p + "/connectorLine", cell.connectorLine), (p + "/typing", cell.typingContainer),
                       (p + "/receiptOld", cell.receiptOld)]
        }
        for (key, m) in view.morphs {
            let p = "morph[\(key)]"
            layers += [(p + "/holder", m.holder), (p + "/bubble", m.bubble), (p + "/body", m.body), (p + "/text", m.text),
                       (p + "/blurred", m.blurred), (p + "/tail", m.tail), (p + "/underlay", m.underlay)]
        }
        layers += [("compose/glass", view.compose.glass), ("clipMask", view.clipMask)]
        for (n, l) in layers {
            var list: [[String: Any]] = []
            for k in l.animationKeys() ?? [] {
                guard let a = l.animation(forKey: k) as? CAPropertyAnimation else { continue }
                var d: [String: Any] = ["keyPath": a.keyPath ?? "", "begin": (a.beginTime * 1e6).rounded() / 1e6, "duration": (a.duration * 1e6).rounded() / 1e6,
                                        "additive": a.isAdditive, "kind": String(describing: type(of: a))]
                if let s = a as? CASpringAnimation {
                    d["from"] = (s.fromValue as? NSNumber)?.doubleValue ?? 0; d["to"] = (s.toValue as? NSNumber)?.doubleValue ?? 0
                    d["stiffness"] = s.stiffness; d["damping"] = s.damping; d["v0"] = s.initialVelocity
                } else if let kf = a as? CAKeyframeAnimation {
                    d["values"] = (kf.values as? [NSNumber])?.prefix(4).map(\.doubleValue) ?? []
                    d["count"] = kf.values?.count ?? 0
                }
                list.append(d)
            }
            list.sort { "\($0["keyPath"]!)\($0["begin"]!)\($0["from"] ?? 0)" < "\($1["keyPath"]!)\($1["begin"]!)\($1["from"] ?? 0)" }
            if !list.isEmpty { out[n] = list }
        }
        let obj: [String: Any] = ["t": t, "layers": out]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    /// Sizes of the SF Symbol images the rows and chrome draw (the image box
    /// decides where the glyph lands).
    static func symbolSizes() -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        let list: [(String, CGFloat, UIImage.SymbolWeight)] = [("plus", 15, .medium), ("video", 18, .regular),
            ("square.and.arrow.down", 11, .medium), ("music.note", 26, .regular), ("heart.fill", 13.6, .bold),
            ("hand.thumbsup.fill", 13.6, .bold), ("questionmark", 13.6, .bold), ("exclamationmark.2", 13.6, .bold)]
        for (n, pt, w) in list {
            if let img = UIImage(systemName: n, withConfiguration: UIImage.SymbolConfiguration(pointSize: pt, weight: w)) {
                out["\(n) \(pt)"] = [Double(img.size.width), Double(img.size.height)]
            }
        }
        return out
    }

    // MARK: Pixels

    /// `CALayer.render(in:)` of the presented tree at 2x, opaque, sRGB.
    static func render(_ view: MessagesWindowView) -> CGImage? {
        let scale: CGFloat = 2
        let size = view.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A y-down context in both apps (UIKit's renderer context; the port's
        // tree is y-down too: `render(in:)` does not apply the root layer's
        // own geometry flip, so the context supplies it).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        view.layer.render(in: ctx)
        return ctx.makeImage()
    }

    static func writePNG(_ img: CGImage?, _ path: String) {
        guard let img, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
