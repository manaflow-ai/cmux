import AppKit
import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The after picture of a reply sent in the thread view (scrawl 1792645422027): the offscreen window
/// view's animated layers (their presentation values) every 1/30 s for 0.8 s from the send, in a
/// filmstrip at `.build/home-thread-send.png` (a fleet step returns it with `--artifact`). The blur
/// filter does not draw offscreen, so the transcript under the thread shows sharp. It checks only that
/// it drew; `HomeThreadSendMotionTests` checks the motion.
@MainActor @Suite(.serialized) struct HomeThreadSendCaptureTests {
    init() { HomeMarkdownPolicy.installSprings() }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    @Test func theSendFilmstrip() throws {
        MessagesLabHomeView.reduceMotionOverride = false
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        DisplayScale.current = 2
        Fixture.renderScale = 2
        RowCell.synchronousBitmaps = true
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let texts = ["The proxied tmux and browser demo is up, with its design on the branch.",
                     "i want it in freestyle vm not local mac",
                     "Understood: the demo moves to a Freestyle VM.",
                     "and the mac mini too"]
        let items = texts.enumerated().map { n, text in
            TranscriptItem(key: IdempotencyKey("k\(n)"), seq: UInt64(n + 1), author: n.isMultiple(of: 2) ? Self.them : Self.me,
                           parts: [.text(text)], createdAt: base.addingTimeInterval(Double(n)), delivery: .committed,
                           messageID: MessageID("msg_\(n)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_capture"), title: "Chief", participants: people, lastSeq: 4,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_capture"), items: items, summary: summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        let view = MessagesWindowView(store: store)
        view.clock = { [weak store] in store?.now ?? 0 }
        view.captureMode = true
        view.layer.isGeometryFlipped = true
        view.layer.speed = 0
        view.frame = CGRect(x: 0, y: 0, width: 520, height: 640)
        var vt = 0.0
        func step(to t: Double) {
            while vt < t {
                vt = min(t, vt + 1.0 / 120)
                view.layer.timeOffset = vt
                store.advance(to: vt)
                view.prepareCapture(at: vt)
                view.layoutIfNeeded()
                view.collection.layoutIfNeeded()
            }
        }
        step(to: 0.05)
        let root = store.state.conversation.messages.first { $0.senderId != store.state.me }
        store.dispatch(.reply(PartRef(messageId: root?.id ?? "", partIndex: 0)))
        step(to: 1.0)
        store.dispatch(.setDraft("need to test it for 2 cases, one is freestyle vm, other one is just my mac mini"))
        step(to: 1.2)
        store.dispatch(.send)
        let scale: CGFloat = 1
        let size = view.bounds.size
        var frames: [CGImage] = []
        for k in 0..<24 {
            step(to: 1.2 + Double(k) / 30)
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            (view.layer.presentation() ?? view.layer).render(in: ctx)
            if let image = ctx.makeImage() { frames.append(image) }
        }
        #expect(frames.count == 24)
        let cols = 6, rows = (frames.count + cols - 1) / cols, gap = 8
        let fw = Int(size.width * scale), fh = Int(size.height * scale)
        guard let sheet = CGContext(data: nil, width: cols * fw + (cols - 1) * gap, height: rows * fh + (rows - 1) * gap, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        sheet.setFillColor(CGColor(gray: 0.5, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        for (i, f) in frames.enumerated() {
            let x = (i % cols) * (fw + gap), y = sheet.height - (i / cols + 1) * fh - (i / cols) * gap
            sheet.draw(f, in: CGRect(x: x, y: y, width: fw, height: fh))
        }
        let image = try #require(sheet.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-thread-send.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
