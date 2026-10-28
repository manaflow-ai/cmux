import AppKit
import CmuxNextDictation
@testable import CmuxNextFileGrid
import CmuxNextFiles
import CmuxNextResources
import CmuxNextWakeups
import CoreGraphics
import Foundation
import Testing

/// p06-scheduler-346 (rule 9): the owners whose makers now pass the app's scheduler. Each one's off-main work lands
/// as a task with a class on the scheduler it was given, not as an unattributed main-actor resume.
///
/// - A hover card's sample report waits in the visible class, and its next sample waits on its visible deadline.
/// - Dictation's words land in the order the engine sent them, and its stop deadline ends the session with them.
/// - A watched folder change lands on the Files model through its scheduler.
/// - A grid tile's rendered thumbnail waits in the visible class.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemainingTargetsOwnerHopTests {
    @Test func aHoverCardsReportWaitsInTheVisibleClassAndItsNextSampleOnItsDeadline() {
        let rig = MainDeadlineRig()
        let source = MockResourceSource(tabs: [TabResourceSources(tabID: "a", title: "a", kind: .terminal, processes: [ProcessKey(pid: 1)])])
        let sampler = ResourceCardSampler()
        sampler.setSource(source, deadlines: rig.deadlines)
        let reports = OwnerHopCounter()
        sampler.open(.tab("a")) { _ in reports.count += 1 }
        #expect(runMainLoop { rig.work.postedCount(.visible) == 1 }, "the sample's report is posted in the visible class")
        #expect(reports.count == 0, "the report waits for the frame")
        rig.frame()
        #expect(reports.count == 1)
        #expect(sampler.isScheduled, "the next sample waits on its deadline")

        rig.fireAndRun()
        #expect(runMainLoop { rig.work.postedCount(.visible) == 1 }, "the deadline's sample posts its report")
        rig.frame()
        #expect(reports.count == 2)

        sampler.close()
        #expect(!sampler.isScheduled, "a closed card samples nothing")
        withExtendedLifetime(source) {}
    }

    @Test func dictationsWordsLandInOrderAndItsStopDeadlineEndsTheSession() {
        let rig = MainDeadlineRig()
        let engine = OwnerHopTranscriber()
        let updates = OwnerHopUpdates()
        let session = DictationSession(deadlines: rig.deadlines, authorizer: OwnerHopAuthorizer(), makeTranscriber: { _ in engine },
                                       locale: { Locale(identifier: "en_US") })
        session.onUpdate = { updates.all.append($0) }
        session.start()
        // Each wait also runs frames: a posted task the turn did not run runs at the next frame.
        #expect(runMainLoop { rig.frame(); return session.phase == .listening }, "the engine's stream opened")

        engine.feed.yield(.partial("hel"))
        engine.feed.yield(.final("hello"))
        #expect(runMainLoop { rig.frame(); return updates.all.last?.text.contains("hello") == true },
                "the words land in the order the engine sent them")

        // The engine misses its flush: the stop deadline ends the session with what was heard.
        session.stop()
        #expect(session.phase == .finalizing)
        #expect(rig.hasArmedWake, "the stop waits on its deadline")
        rig.fireAndRun()
        #expect(runMainLoop { rig.frame(); return session.phase == .idle }, "the stop deadline ends the session")
        #expect(updates.all.last?.text.contains("hello") == true, "the session ends with the words it heard")
        #expect(!session.holdsResources)
    }

    @Test func aWatchedFolderChangeLandsOnTheFilesModelThroughItsScheduler() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-files-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "old"))
        let watcher = OwnerHopFolderFeed()
        let model = FileBrowserModel(folder: folder, work: linklessMainWork(), watcher: watcher)
        await model.reload()
        #expect(model.entries.map(\.name) == ["old"])

        try Data().write(to: folder.appending(path: "new"))
        watcher.feed.yield(.items(["new"]))
        #expect(runMainLoop { model.entries.map(\.name) == ["new", "old"] }, "the watched change's rows land")
        model.stop()
    }

    @Test func aGridTilesThumbnailWaitsInTheVisibleClass() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let grid = FileGridView(cache: ThumbnailCache(capacity: 4, generator: OwnerHopThumbnails()), work: rig.work,
                                appearance: FileGridAppearance(tileSide: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        grid.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(grid)
        grid.show([FileGridItem(url: URL(fileURLWithPath: "/shots/shot.png"), size: 1, modified: Date(timeIntervalSinceReferenceDate: 1), sourceID: "s")])
        // sync-layout: the collection view makes and configures its tiles in this layout
        grid.layoutSubtreeIfNeeded()
        // sync-layout: the collection view makes and configures its tiles in this layout
        grid.collectionView.layoutSubtreeIfNeeded()
        #expect(runMainLoop { rig.work.postedCount(.visible) == 1 }, "the rendered thumbnail is posted in the visible class")
        rig.frame()
        #expect(rig.work.postedCount(.visible) == 0, "the frame lands it")
    }
}

/// A count the test's main-actor closures raise.
@MainActor final class OwnerHopCounter {
    var count = 0
}

/// Every dictation update, in order.
@MainActor final class OwnerHopUpdates {
    var all: [DictationUpdate] = []
}

/// Microphone and speech recognition granted.
nonisolated struct OwnerHopAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

/// An engine whose events the test sends; its finish flushes nothing (a missed flush).
nonisolated final class OwnerHopTranscriber: SpeechTranscribing {
    let feed: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation
    private let events: AsyncThrowingStream<DictationTranscriptionEvent, any Error>

    init() {
        (events, feed) = AsyncThrowingStream.makeStream()
    }

    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> { events }

    func finishTranscribing() async {}
}

/// A folder watcher whose changes the test sends.
nonisolated struct OwnerHopFolderFeed: FolderWatching {
    let feed: AsyncStream<FolderChange>.Continuation
    private let stream: AsyncStream<FolderChange>

    init() {
        (stream, feed) = AsyncStream.makeStream()
    }

    func changes(in folder: URL) -> AsyncStream<FolderChange> { stream }
}

/// One 1x1 picture for every file; no movie lengths.
nonisolated final class OwnerHopThumbnails: ThumbnailGenerating {
    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    func duration(for url: URL) async -> TimeInterval? { nil }
}
