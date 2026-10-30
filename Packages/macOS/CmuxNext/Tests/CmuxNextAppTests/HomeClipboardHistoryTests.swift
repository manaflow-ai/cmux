import AppKit
@testable import CmuxNextHome
import Testing

/// The Chief composer's + menu: Attach Files or Images… first, then the recent clipboard
/// (`home.clipboardHistory`). The history's rules are a value (`HomeClipboardLog`), checked here
/// over generated copy sequences, and the reader runs over a fake pasteboard (a ci-step mini has
/// no pasteboard server).
@MainActor
struct HomeClipboardHistoryTests {
    private struct Board: HomePasteboardContents {
        var types: [NSPasteboard.PasteboardType: Data] = [:]
        var text: String?
        var fileURLs: [URL] = []

        func hasType(_ wanted: [NSPasteboard.PasteboardType]) -> Bool {
            wanted.contains { $0 == .string ? text != nil : ($0 == .fileURL ? !fileURLs.isEmpty : types[$0] != nil) }
        }
        func data(forType type: NSPasteboard.PasteboardType) -> Data? { types[type] }
        func string(forType type: NSPasteboard.PasteboardType) -> String? { type == .string ? text : nil }
    }

    private final class Source: HomeClipboardSource {
        var changeCount = 0
        var board = Board()
        var readsWithoutAsking = true
        var reads = 0
        var contents: any HomePasteboardContents { reads += 1; return board }
        func copy(_ board: Board) { self.board = board; changeCount += 1 }
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // MARK: What is kept

    @Test func textAndPicturesAreKept() {
        #expect(HomeClipboardLog.content(of: Board(text: "hello world")) == .text("hello world"))
        #expect(HomeClipboardLog.content(of: Board(types: [.png: Self.png]))
            == .image(Self.png, typeIdentifier: NSPasteboard.PasteboardType.png.rawValue))
        // A browser's Copy Image (the picture plus its link) is the picture, as a paste attaches it.
        #expect(HomeClipboardLog.content(of: Board(types: [.png: Self.png], text: "https://example.com/cat.png"))
            == .image(Self.png, typeIdentifier: NSPasteboard.PasteboardType.png.rawValue))
        // Rich text with a picture of itself is the text.
        #expect(HomeClipboardLog.content(of: Board(types: [.png: Self.png], text: "a paragraph")) == .text("a paragraph"))
    }

    @Test func markedFilesBlankAndOversizedCopiesAreSkipped() {
        for marker in HomeClipboardLog.skippedTypes {
            #expect(HomeClipboardLog.content(of: Board(types: [marker: Data()], text: "hunter2")) == nil, "\(marker.rawValue)")
            #expect(HomeClipboardLog.content(of: Board(types: [marker: Data(), .png: Self.png])) == nil, "\(marker.rawValue)")
        }
        // The markers cmux's own password copy writes (ConcealedPasteboard) are among them.
        #expect(HomeClipboardLog.skippedTypes.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        #expect(HomeClipboardLog.skippedTypes.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        #expect(HomeClipboardLog.content(of: Board(text: "x.txt", fileURLs: [URL(fileURLWithPath: "/tmp/x.txt")])) == nil)
        #expect(HomeClipboardLog.content(of: Board(text: "  \n\t ")) == nil)
        #expect(HomeClipboardLog.content(of: Board(text: String(repeating: "a", count: HomeClipboardLog.maxTextBytes + 1))) == nil)
        let huge = Data(count: HomeClipboardLog.maxImageBytes + 1)
        #expect(HomeClipboardLog.content(of: Board(types: [.png: huge])) == nil)
    }

    // MARK: The log's invariants

    /// Over random copy sequences: newest first, no repeats, never over the caps, each change count read once.
    @Test func randomCopySequencesKeepTheInvariants() {
        var rng = SplitMix(seed: 0x22_6000)
        for _ in 0..<200 {
            let capacity = Int.random(in: 1...8, using: &rng)
            let maxBytes = Int.random(in: 4...64, using: &rng)
            var log = HomeClipboardLog(capacity: capacity, maxTotalBytes: maxBytes)
            var count = 0
            var lastKept: HomeClipboardContent?
            for _ in 0..<40 {
                // Sometimes the same change count again (an activation with no new copy).
                if Bool.random(using: &rng) || count == 0 { count += 1 }
                let roll = Int.random(in: 0..<10, using: &rng)
                let content: HomeClipboardContent? = roll == 0 ? nil
                    : roll < 7 ? .text(String(repeating: "t", count: Int.random(in: 1...6, using: &rng)))
                    : .image(Data(repeating: UInt8(roll), count: Int.random(in: 1...6, using: &rng)), typeIdentifier: "public.png")
                let fresh = log.needsRead(changeCount: count)
                let before = log
                let changed = log.record(content, changeCount: count)
                if !fresh { #expect(log == before && !changed) }
                if fresh, let content {
                    #expect(log.entries.first?.content == content)
                    lastKept = content
                }
                #expect(log.entries.count <= capacity)
                #expect(Set(log.entries.map(\.content)).count == log.entries.count)
                #expect(log.entries.map(\.id) == log.entries.map(\.id).sorted(by: >))
                let total = log.entries.reduce(0) { $0 + $1.content.byteCount }
                #expect(total <= maxBytes || log.entries.count == 1)
                if let lastKept { #expect(log.entries.first?.content == lastKept) }
            }
        }
    }

    @Test func aRepeatedCopyMovesToTheFront() {
        var log = HomeClipboardLog()
        log.record(.text("a"), changeCount: 1)
        log.record(.text("b"), changeCount: 2)
        log.record(.text("a"), changeCount: 3)
        #expect(log.entries.map(\.content) == [.text("a"), .text("b")])
        #expect(log.newest(1).map(\.content) == [.text("a")])
    }

    // MARK: Reading the pasteboard

    @Test func readsOnlyWhenTheClipboardChangedAndWhileOn() {
        let source = Source()
        let history = HomeClipboardHistory(pasteboard: source)
        // Off until the app wires the setting.
        source.copy(Board(text: "first"))
        #expect(history.recent(6).isEmpty)
        #expect(source.reads == 0)
        history.isEnabled = { true }
        #expect(history.recent(6).map(\.content) == [.text("first")])
        #expect(history.recent(6).count == 1)
        #expect(source.reads == 1, "the same change count is read once")
        source.copy(Board(text: "second"))
        history.recordIfAllowed(backgroundRead: true)
        #expect(history.recent(6).map(\.content) == [.text("second"), .text("first")])

        // Off: nothing is read, and the history goes.
        var on = false
        history.isEnabled = { on }
        source.copy(Board(text: "third"))
        let reads = source.reads
        history.recordIfAllowed(backgroundRead: true)
        #expect(history.recent(6).isEmpty)
        #expect(history.log.entries.isEmpty)
        #expect(source.reads == reads)
        on = true
        #expect(history.recent(6).map(\.content) == [.text("third")])
    }

    @Test func anActivationNeverReadsWhereTheSystemWouldAsk() {
        let source = Source()
        source.readsWithoutAsking = false
        let history = HomeClipboardHistory(pasteboard: source)
        history.isEnabled = { true }
        source.copy(Board(text: "secret"))
        history.recordIfAllowed(backgroundRead: true)
        #expect(source.reads == 0)
        // Opening the + menu is the person's own click: it reads.
        #expect(history.recent(6).map(\.content) == [.text("secret")])
    }

    /// Only "Always Allow" (or no pasteboard privacy) reads at activation; macOS's default asks
    /// once enforced, so it reads only with the Debug Settings opt-in.
    @Test func activationReadsOnlyWhereMacOSDoesNotAsk() {
        for access in [HomeClipboardAccess.noPrivacy, .alwaysAllow] {
            #expect(access.readsWithoutAsking(defaultReads: false) && access.readsWithoutAsking(defaultReads: true))
        }
        for access in [HomeClipboardAccess.ask, .alwaysDeny] {
            #expect(!access.readsWithoutAsking(defaultReads: false) && !access.readsWithoutAsking(defaultReads: true))
        }
        #expect(!HomeClipboardAccess.default.readsWithoutAsking(defaultReads: false))
        #expect(HomeClipboardAccess.default.readsWithoutAsking(defaultReads: true))
        #expect(HomeTunables.clipboardReadAtDefaultAccess.defaultValue == false)
    }

    // MARK: The menu

    @Test func theMenuLeadsWithAttachThenTheClipboard() {
        #expect(HomePlusMenuModel.sections(clipboard: []).sections == [[.attachFiles]])
        let entries = [HomeClipboardEntry(id: 2, content: .text("b")), HomeClipboardEntry(id: 1, content: .text("a"))]
        let model = HomePlusMenuModel.sections(clipboard: entries)
        #expect(model.sections == [[.attachFiles], entries.map { .clipboard($0) }])
        let menu = HomePlusMenu.make(model, thumbnail: { _ in nil }) { _ in }
        #expect(menu.items.map(\.title) == [HomeStrings.plusMenuAttachFiles, "", HomeStrings.plusMenuClipboard, "b", "a"])
        #expect(menu.items[1].isSeparatorItem)
    }

    @Test func aTextRowIsOneShortLine() {
        #expect(HomePlusMenuModel.snippet("one\n\n  two\tthree") == "one two three")
        let long = HomePlusMenuModel.snippet(String(repeating: "word ", count: 40), limit: 20)
        #expect(long.count <= 20 && long.hasSuffix("…") && !long.contains("\n"))
    }
}

/// A seeded generator, so a failing sequence repeats.
private nonisolated struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
