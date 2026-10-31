import AppKit
import CmuxHomeCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Home against the MessagesLab demo on the demo's own fixture (MessagesLab shared/conversation.json, vendored by
/// vendor.tsv): its four threads (an early reply under a later question, a 5-reply thread broken by other rows, a
/// late 3-reply thread, a 3-reply block right under its root), tapbacks, link cards and receipts.
///
/// The lab path is MessagesLab's own: its conversation straight into the vendored `Store`, as the demo's
/// Host.swift does. The Home path is cmux's: the same messages as HomeStore `TranscriptItem`s (thread root,
/// reply part, reactions, read cursor) through `ProjectionCore`, the Home pane's projection. Both draw in one
/// `ChatController` each at the demo's window size. Parts Home cannot carry without a blob store (the
/// fixture's pictures, files and locations) are left out of both, and a link card keeps the fields a Home
/// link preview carries (no picture, the dark card).
///
/// `LAB_PARITY_OUT=DIR` also writes both renders (`lab-*.png`, `home-*.png`) at each thread, for the gallery.
@MainActor @Suite(.serialized) struct LabFixtureParityTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let size = NSSize(width: 628, height: 1041)
    static let me = ParticipantID("me")
    static let other = ParticipantID("instinct")
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/conversation.json")

    /// The demo's conversation, without the parts Home cannot carry here (see the suite).
    static func labConversation() throws -> MessagesLabHome.Conversation {
        var conv = try JSONDecoder().decode(MessagesLabHome.Conversation.self, from: Data(contentsOf: fixture))
        conv.messages = conv.messages.compactMap { m in
            var m = m
            m.parts = m.parts.compactMap { p in
                switch p {
                // A person's text in Home carries only its mentions, and its links are the ones MessagesLab's own
                // send detects (TextParts); the fixture's bold run, detected dates and hand-made link runs are lab
                // data with no HomeStore field.
                case let .text(t, runs):
                    return .text(t, runs: (runs.filter { $0.mention != nil } + TextParts.linkRuns(t)).sorted { $0.start < $1.start })
                case let .link(url, title, site, _, _):
                    let host = URL(string: url).map(TextParts.host) ?? url
                    return .link(url: url, title: title ?? host, siteName: site ?? host, image: nil, theme: "dark")
                default: return nil
                }
            }
            guard !m.parts.isEmpty else { return nil }
            // Home has no per-message receipt: a send is read when the other side's read cursor passed it.
            if m.senderId == "me", case .sending? = m.status { m.status = nil }
            // A HomeStore reaction has no time (only Tapback Details would show it).
            m.reactions = m.reactions.filter { $0.partIndex < m.parts.count }.map { var r = $0; r.at = ""; return r }
            return m
        }
        return conv
    }

    /// The conversation as the HomeStore items and summary the Home pane projects.
    static func homeItems(_ conv: MessagesLabHome.Conversation) -> ([TranscriptItem], ConversationSummary) {
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      // A person, not an agent: an agent's text is Markdown in Home (a deliberate difference).
                      CmuxHomeCore.Participant(id: other, kind: .human, displayName: "Instinct")]
        let items = conv.messages.enumerated().map { i, m in
            var item = TranscriptItem(key: IdempotencyKey(m.id), seq: Seq(i + 1), author: ParticipantID(m.senderId),
                                      parts: m.parts.map(homePart), createdAt: m.date, delivery: .committed,
                                      reactions: m.reactions.map { r in
                                          CmuxHomeCore.Reaction(author: ParticipantID(r.senderId), partIndex: r.partIndex, kind: HomeMapping.kind(r.kind))
                                      },
                                      replyTo: m.replyTo.map { CmuxHomeCore.PartRef(message: MessageID($0.messageId), partIndex: $0.partIndex) },
                                      threadRoot: m.replyTo.map { MessageID($0.messageId) }, messageID: MessageID(m.id))
            item.editedAt = m.edits?.last.map { Instant.parse($0.at) }
            return item
        }
        let lastRead = conv.messages.last { if case .read? = $0.status { return true } else { return false } }
        let readAt: Date = { if case let .read(at)? = lastRead?.status { return Instant.parse(at) }; return Date() }()
        let readSeq = Seq((conv.messages.lastIndex { $0.id == lastRead?.id } ?? 0) + 1)
        let first = items.first?.createdAt ?? Date()
        let summary = ConversationSummary(id: ConversationID(conv.id), title: conv.title, participants: people, lastSeq: Seq(items.count),
                                          createdAt: first, updatedAt: items.last?.createdAt ?? first,
                                          readCursors: [other: readSeq], readCursorTimes: [other: readAt])
        return (items, summary)
    }

    static func homePart(_ p: Part) -> MessagePart {
        switch p {
        case let .text(t, runs):
            return .text(t, mentions: runs.compactMap { r in r.mention.map { Mention(start: r.start, length: r.length, participant: ParticipantID($0)) } })
        case let .link(url, title, site, _, _): return .linkPreview(LinkPreview(url: url, title: title, site: site))
        default: return .text("")
        }
    }

    /// A pane in an offscreen window at the demo's size over `conv`.
    static func pane(_ conv: MessagesLabHome.Conversation, mode: ThreadMode? = nil) -> (NSWindow, ChatController) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(origin: .zero, size: size)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: 0, total: conv.messages.count)
        if let mode { controller.store?.setThreadMode(mode) }
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        return (window, controller)
    }

    /// MessagesLab's own path: the demo's Store over the conversation, in its default thread mode (Host.swift).
    static func labPane() throws -> (NSWindow, ChatController) {
        try pane(labConversation(), mode: .messages)
    }

    /// Home's path: HomeStore items through ProjectionCore, as `HomeProjection` installs a conversation.
    static func homePane() throws -> (NSWindow, ChatController) {
        let conv = try labConversation()
        let (items, summary) = homeItems(conv)
        var core = ProjectionCore(me: me)
        let (projected, w) = core.install(ConversationID(conv.id), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(origin: .zero, size: size)), wake: NoWake())
        window.contentView = controller.host
        controller.install(projected, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        return (window, controller)
    }

    /// Every live row as `key kind gap height`, top to bottom, plus the row's whole spec for an exact compare.
    static func rows(_ c: ChatController) -> [(line: String, spec: RowSpec)] {
        guard let demo = c.demo else { return [] }
        return demo.model.rows.filter { !$0.ghost }.map { r in
            let kind = Mirror(reflecting: r.spec.kind).children.first?.label ?? "\(r.spec.kind)"
            return ("\(r.spec.key) \(kind) gap \(r.spec.gap) height \(r.spec.height)", r.spec)
        }
    }

    /// Row keys whose spec differs between the two paths (or that only one path has), with both lines.
    static func differences(lab: [(line: String, spec: RowSpec)], home: [(line: String, spec: RowSpec)]) -> [String] {
        let l = Dictionary(lab.map { ($0.spec.key, $0) }, uniquingKeysWith: { a, _ in a })
        let h = Dictionary(home.map { ($0.spec.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for r in lab where h[r.spec.key]?.spec != r.spec {
            out.append("lab:  \(r.line)\nhome: \(h[r.spec.key]?.line ?? "(none)")" + fieldDiff(r.spec, h[r.spec.key]?.spec))
        }
        for r in home where l[r.spec.key] == nil { out.append("lab:  (none)\nhome: \(r.line)") }
        if out.isEmpty, lab.map(\.spec.key) != home.map(\.spec.key) { out.append("row order differs") }
        return out
    }

    /// The fields of a part row that differ (empty for other rows).
    static func fieldDiff(_ a: RowSpec, _ b: RowSpec?) -> String {
        guard case let .part(pa) = a.kind, let b, case let .part(pb) = b.kind else { return "" }
        let fb = Dictionary(Mirror(reflecting: pb).children.compactMap { c in c.label.map { ($0, "\(c.value)") } }, uniquingKeysWith: { x, _ in x })
        return Mirror(reflecting: pa).children.compactMap { c in
            guard let l = c.label, fb[l] != "\(c.value)" else { return nil }
            return "\n   \(l): lab \(String("\(c.value)".prefix(160))) home \(String((fb[l] ?? "").prefix(160)))"
        }.joined()
    }

    @Test func homeLaysOutTheDemoFixtureAsTheDemo() throws {
        HomeMarkdownPolicy.installSprings()
        let (lw, lab) = try Self.labPane()
        defer { lw.close() }
        let (hw, home) = try Self.homePane()
        defer { hw.close() }
        let diff = Self.differences(lab: Self.rows(lab), home: Self.rows(home))
        #expect(diff.isEmpty, "\(diff.count) rows differ from the demo:\n\(diff.prefix(40).joined(separator: "\n"))")
    }

    /// The thread rows (previews, connectors, "N Replies") are the demo's, key for key.
    @Test func homeDrawsTheDemoThreadRows() throws {
        HomeMarkdownPolicy.installSprings()
        let (lw, lab) = try Self.labPane()
        defer { lw.close() }
        let (hw, home) = try Self.homePane()
        defer { hw.close() }
        func threadRows(_ c: ChatController) -> [String] {
            Self.rows(c).filter { r in
                switch r.spec.kind {
                case .threadPreview, .replies: return true
                case let .part(p): return p.connectorRoot != nil
                default: return false
                }
            }.map(\.line)
        }
        #expect(threadRows(home) == threadRows(lab))
    }

    // MARK: Gallery renders

    /// The window at the bottom, then scrolled so each thread root shows near the top.
    @Test func renders() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LAB_PARITY_OUT"] else { return }
        HomeMarkdownPolicy.installSprings()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, make) in [("lab", Self.labPane), ("home", Self.homePane)] {
            let (w, c) = try make()
            defer { w.close() }
            guard let demo = c.demo else { continue }
            let stops: [(String, String?)] = [("bottom", nil), ("thread-s07", "s07"), ("thread-t01", "t01"), ("thread-s04", "x01"), ("thread-dogen", "dogen")]
            for (stop, id) in stops {
                if let id, let i = demo.model.rows.firstIndex(where: { RowBuilder.key($0.spec.key, belongsTo: id) }) {
                    demo.collection.contentOffset.y = min(demo.pinnedOffset, max(demo.minOffset, demo.layout.rowsTop + demo.model.offsets[i] - 140))
                } else {
                    demo.collection.contentOffset.y = demo.pinnedOffset
                }
                demo.layoutIfNeeded()
                for _ in 0..<10 {
                    demo.refreshVisibleCells()
                    try await Task.sleep(for: .milliseconds(120))
                }
                try Self.write(c.host, to: "\(dir)/\(name)-\(stop).png")
            }
        }
    }

    static func write(_ view: NSView, to path: String) throws {
        guard let layer = view.layer else { return }
        let scale: CGFloat = 2, size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
