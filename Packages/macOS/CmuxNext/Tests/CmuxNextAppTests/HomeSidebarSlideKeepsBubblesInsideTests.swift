import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// a102: my blue bubbles are not cut at the chat's right edge while the window's sidebar
/// slides (every frame of its width motion resizes the main pane card and the Home chat in it).
/// `HomeTranscriptLayerKeepsBubblesInsideTests` checks the row model and the view frames; this
/// suite checks what is drawn: each of my rows' bitmap, its blue fill (gradient and bubble mask)
/// and its cell, in the card's own coordinates, on every frame of the slide, with and without a
/// reply streaming, and with no implicit layer animation.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeSidebarSlideKeepsBubblesInsideTests {
    typealias Layer = HomeTranscriptLayerKeepsBubblesInsideTests

    struct Rig {
        let frames: Layer.Frames
        let window: NSWindow
        let root: WindowRootView
        let view: HomeNativeTranscriptView
        let store: Store
        var core: ProjectionCore
    }

    /// A window with the real sidebar and main pane card, Home's chat as the card's content.
    static func rig(width: CGFloat) -> Rig {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: Layer.id, me: Layer.me)
        root.show(view)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        view.frame = root.contentHost.bounds
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var items = [TranscriptItem(key: IdempotencyKey("k0"), seq: 1, author: Layer.chief, parts: [.text("Started a102.")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_0"))]
        // Short and long messages of mine: a one-line bubble sits nearest the right edge's
        // corners, a wrapped one fills the row's whole bubble width.
        for (i, text) in ["ok", "Ship it now please", Layer.long, Layer.long + " " + Layer.long].enumerated() {
            items.append(TranscriptItem(key: IdempotencyKey("m\(i)"), seq: UInt64(i + 2), author: Layer.me, parts: [.text(text)],
                                        createdAt: base.addingTimeInterval(Double(i + 1)), delivery: .committed,
                                        messageID: MessageID("msg_m\(i)")))
        }
        var core = ProjectionCore(me: Layer.me)
        var summary = Layer.summary
        summary.lastSeq = UInt64(items.count)
        let (conv, w) = core.install(Layer.id, items: items, summary: summary)
        let frames = Layer.Frames()
        view.transcript.controller.nextFrame = { [frames] f in frames.work.append(f) }
        let store = view.transcript.controller.install(conv, windowStart: w.start, total: w.total)
        root.layoutSubtreeIfNeeded()
        return Rig(frames: frames, window: window, root: root, view: view, store: store, core: core)
    }

    static func stream(_ rig: inout Rig, _ text: String) {
        let rows = [HomeStreamRow(turn: Layer.turn, author: Layer.chief, text: text)]
        for action in rig.core.streams(rows, state: rig.store.state) { rig.store.dispatch(action) }
    }

    /// The implicit actions AppKit and Core Animation add to a plain layer whose frame changes
    /// outside a transaction with actions disabled: a bubble on one of them trails the slide.
    static let implicitKeys: Set<String> = ["bounds", "position", "frame", "bounds.size", "position.x"]

    /// What is drawn for my rows ends inside the chat, and inside the card, on this frame.
    static func check(_ rig: Rig, _ step: String) {
        let lab = rig.view.transcript
        guard let demo = lab.controller.demo else {
            Issue.record("\(step): no transcript")
            return
        }
        let card = rig.root.contentHost
        #expect(rig.view.frame == card.bounds, "\(step): Home \(rig.view.frame) in a card of \(card.bounds)")
        let inner = demo.bounds.width
        #expect(abs(inner - card.bounds.width / lab.zoom) < 0.001, "\(step): chat \(inner) pt in a \(card.bounds.width) pt card at zoom \(lab.zoom)")
        let root = demo.layer
        var mine = 0
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, case let .part(p) = spec.kind, p.outgoing else { continue }
            mine += 1
            let key = "\(step) \(spec.key)"
            #expect(spec.width == inner, "\(key): laid out for \(spec.width) pt in \(inner) pt")
            let cellBox = cell.layer.convert(cell.layer.bounds, to: root)
            #expect(cellBox.maxX <= inner + 0.5, "\(key): its cell ends at \(cellBox.maxX) pt, past \(inner) pt")
            if cell.bitmap.contents != nil {
                let drawn = cell.bitmap.convert(cell.bitmap.bounds, to: root)
                #expect(drawn.maxX <= inner + 0.5, "\(key): its bitmap ends at \(drawn.maxX) pt, past \(inner) pt")
                let body = cell.contentView.layer.convert(RowDraw.bodyRect(spec), to: root)
                #expect(drawn.maxX >= body.maxX - 0.5, "\(key): its bitmap ends at \(drawn.maxX) pt, before its bubble's \(body.maxX) pt")
            }
            if !cell.fillContainer.isHidden {
                let mask = cell.fillContainer.mask ?? cell.fillMask
                let shape = mask.frame
                let fill = cell.fillGradient.frame
                #expect(fill.minX <= shape.minX + 0.5 && fill.maxX >= shape.maxX - 0.5,
                        "\(key): the blue fill spans \(fill.minX)...\(fill.maxX) pt under a bubble at \(shape.minX)...\(shape.maxX) pt")
                let inChat = cell.fillContainer.convert(shape, to: root)
                #expect(inChat.maxX <= inner + 0.5, "\(key): the blue bubble ends at \(inChat.maxX) pt, past \(inner) pt")
                let body = cell.contentView.layer.convert(RowDraw.bodyRect(spec), to: root)
                #expect(abs(inChat.maxX - body.maxX) < 1.5, "\(key): the blue bubble ends at \(inChat.maxX) pt, its row's bubble at \(body.maxX) pt")
            }
            for layer in [cell.layer, cell.contentView.layer, cell.bitmap, cell.fillContainer, cell.fillGradient, cell.fillMask, cell.fillMaskImage] {
                let moving = Set(layer.animationKeys() ?? []).intersection(implicitKeys)
                #expect(moving.isEmpty, "\(key): a bubble layer animates \(moving.sorted()) behind the slide")
            }
        }
        #expect(mine > 0, "\(step): none of my messages is shown")
    }

    /// The sidebar slides closed and open again over 12 frames each, as its motion steps it, one
    /// window layout per frame; the chat's next-frame work runs between frames.
    @Test(arguments: [900.0, 1300.0])
    func theSidebarSlideKeepsMyBubblesInside(width: Double) {
        var rig = Self.rig(width: CGFloat(width))
        defer { rig.window.close() }
        let open = rig.root.sidebar.widthConstraint.constant
        #expect(open > 0, "the sidebar starts open")
        Self.check(rig, "at rest")
        var chunk = "Working on it"
        rig.root.sidebar.isWidthAnimating = true
        let legs: [(String, CGFloat, CGFloat)] = [("close", open, 0), ("open", 0, open)]
        for (leg, from, to) in legs {
            for i in 1...12 {
                let t = CGFloat(i) / 12
                let eased = t * t * (3 - 2 * t)
                rig.frames.start()
                rig.root.sidebar.widthConstraint.constant = (from + (to - from) * eased).rounded(.toNearestOrAwayFromZero)
                if i % 3 == 0 {
                    chunk += " more"
                    Self.stream(&rig, chunk)
                }
                rig.root.layoutSubtreeIfNeeded()
                Self.check(rig, "\(leg) frame \(i) sidebar \(rig.root.sidebar.widthConstraint.constant)")
            }
        }
        rig.root.sidebar.isWidthAnimating = false
        rig.frames.start()
        rig.root.layoutSubtreeIfNeeded()
        Self.check(rig, "landed")
    }
}
