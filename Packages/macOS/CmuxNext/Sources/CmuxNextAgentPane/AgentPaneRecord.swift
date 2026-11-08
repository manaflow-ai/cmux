import AppKit
import AVFoundation
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import CoreMedia
import CryptoKit
import os
import ScreenCaptureKit

/// The capture bar's Record (plans/cmux-next/capture-bar-DESIGN.md): `capture.record.start` films
/// the cmux window that hosts the pane, `capture.record.stop` ends it and answers the movie. The
/// frames come from ScreenCaptureKit's current-process content (macOS 14.4 and later), which needs
/// no Screen Recording grant, and go to an H.264 `.mp4` in the temporary folder
/// (``folder``). One recording at a time in the app. It stops by itself
/// after ``maxSeconds``, when its window closes and when the app quits; every end releases the
/// stream and the writer. Nothing runs on the main thread per frame.
@MainActor
final class AgentPaneRecorder {
    static let shared = AgentPaneRecorder()
    /// A recording stops by itself after this long (the design's `maxSeconds`).
    nonisolated static let maxSeconds = 300
    /// At most this many frames a second.
    nonisolated static let framesPerSecond: Int32 = 60
    /// The movie's longest side, in pixels.
    nonisolated static let maxSide = 2560
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.record")

    /// Where recordings go: one folder per recording, so its file keeps the plain name. A
    /// recording that is never attached goes with the temporary folder.
    nonisolated static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture", isDirectory: true)

    private var current: AgentPaneRecording?
    private var starting = false
    /// Its window's close, move and resize, and the app's quit, only while a recording runs.
    private var observers: [MainActorObservation] = []
    /// The movies this process wrote, exactly as the page was given them (as made, never resolved):
    /// the only paths `capture.copy` and `capture.save` take.
    private(set) var written: Set<String> = []
    /// Each written movie's file identity when the page was given its path.
    private var identities: [String: FileIdentity] = [:]
    /// A stop is finalizing a movie: no other recording starts until it is done (one at a time),
    /// and a quit waits for it (``finishForQuit()``).
    private var finishing = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by the quit: a stop that ends after it puts its movie on the clipboard too, since its
    /// page's chip may come after the composers were saved.
    private var quitting = false
    private var quitKept: [NSURL] = []
    /// Whether the capture bar's save panel is up: one at a time.
    var saving = false
    /// The bar's last press (``AgentPaneCaptureBar/toggle(on:)``): the chat it opened on, held
    /// weakly, and its Pane shot, the pane focused at the press as on screen (a person's own
    /// capture, unmasked; the closure holds the pane weakly). Only that chat's page may take it.
    private struct Press {
        weak var view: AgentPaneView?
        let paneImage: (@MainActor () async -> CGImage?)?
    }

    private var press: Press?
    /// The chat whose page started the running recording: it hears when the recording ends by itself.
    private weak var recordingView: AgentPaneView?
    /// The pane whose page started it, the only one that may stop it and take the movie, and its
    /// chat then, whose Chat Uploads folder keeps the movie.
    private weak var recordingModel: AgentPaneModel?
    private var recordingSession: String?
    /// Whether its chat was incognito when it started (``AgentPaneModel/sendIsIncognito``; unknown
    /// counts as incognito): a quit discards its movie with the chat.
    private var recordingIncognito = true
    /// Recordings that ended by themselves and were not collected yet when another started: each
    /// waits for its own pane's `capture.record.stop`, and goes when that pane does.
    private struct Leftover {
        weak var model: AgentPaneModel?
        let session: String?
        let incognito: Bool
        let recording: AgentPaneRecording
        let since: Date
    }

    private var leftovers: [Leftover] = []
    /// Each pane's last screenshot from ``AgentPaneCapture/reply(to:in:)``, as its SHA-256 (not
    /// its bytes, so a pane holds 32 bytes): the only bytes that pane's Copy and Save take, once,
    /// so a page never writes bytes of its own to the clipboard or a file.
    private struct Shot {
        weak var model: AgentPaneModel?
        let digest: Data
        let at: Date
    }

    /// How long a handed screenshot's Copy or Save stays open when the page never spends it: the
    /// page asks at once, so this only bounds a shot whose bytes a page kept.
    nonisolated static let shotLifetime: TimeInterval = 30

    private var shots: [Shot] = []

    func pressed(_ view: AgentPaneView, paneImage: (@MainActor () async -> CGImage?)?) {
        press = Press(view: view, paneImage: paneImage)
    }

    /// The Pane shot of the bar's last press, when `model`'s chat is the one it opened on; nil
    /// for another chat (chat A's press must never give chat B's page A's pane).
    func paneImage(for model: AgentPaneModel) -> (@MainActor () async -> CGImage?)? {
        guard let press, let view = press.view, view.model === model else { return nil }
        return press.paneImage
    }

    /// The chat view of `model` when the bar's last press opened on it.
    func view(for model: AgentPaneModel) -> AgentPaneView? {
        press?.view.flatMap { $0.model === model ? $0 : nil }
    }

    /// Starts filming `window`: `{started: true}`, `capture.busy` while one runs, `capture.failed`
    /// when ScreenCaptureKit could not start (no window, macOS before 14.4).
    func start(in window: NSWindow, for model: AgentPaneModel, cursor: Bool, clicks: Bool) async -> [String: Any] {
        guard !starting, !finishing, current?.isEnding != false else {
            return AgentPaneReply.failure(code: "capture.busy", message: AgentPaneModel.captureFailedMessage)
        }
        // One that ended whose end has not reached the main actor yet: retired as its end would.
        if let stale = current { retire(stale) }
        dropOrphans()
        removeObservers()
        guard window.windowNumber > 0, window.isVisible, !window.isMiniaturized else {
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        let id = UUID().uuidString
        let kept = Set(written.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent })
            .union(leftovers.map(\.recording.folderName)).union([id])
        Task.detached(priority: .utility) { Self.sweep(Self.folder, keeping: kept, now: Date()) }
        let folder = Self.folder.appendingPathComponent(id, isDirectory: true)
        let recording = AgentPaneRecording(AgentPaneRecording.Options(
            window: CGWindowID(window.windowNumber), scale: Double(window.backingScaleFactor), cursor: cursor, clicks: clicks,
            url: folder.appendingPathComponent(Self.name(Date())), windows: Self.family(window))) { [weak self] over in
            MainDelivery().run { self?.ended(over) }
        }
        starting = true
        defer { starting = false }
        do {
            try await recording.start()
        } catch {
            Self.logger.error("capture.record.start failed: \(String(describing: error), privacy: .public)")
            Task.detached(priority: .utility) { await recording.discard() }
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        began(recording, for: model, view: view(for: model))
        // The stream follows the window when it moves or resizes; a close or the quit ends it.
        observers = [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            MainActorObservation(name, object: window) { [weak window] in
                guard name != NSWindow.willCloseNotification, let window else { return recording.end() }
                recording.follow(Self.globalFrame(window))
            }
        } + [MainActorObservation(NSApplication.willTerminateNotification) { recording.end() }]
        // The window closed while ScreenCaptureKit started: no close notice comes any more. One
        // that ended while it started (its end found it not yet current) is retired now.
        if !window.isVisible { recording.end() }
        if recording.isEnding { ended(recording) }
        return AgentPaneReply.success(["started": true])
    }

    /// Ends the recording `model`'s page started (or collects one of its that ended by itself) and
    /// answers `{path, name, seconds}`, or `{cancelled: true}` when it has none (chat B's page never
    /// stops chat A's recording or learns its file) or it has no frame (its folder is removed
    /// then). The movie moves into its chat's Chat Uploads folder (``ChatUploadFolders``), which
    /// lives as long as the chat's other uploads, so a draft or a sent message keeps its video past
    /// a relaunch.
    func stop(for model: AgentPaneModel) async -> [String: Any] {
        let recording: AgentPaneRecording, session: String?, incognito: Bool
        if let running = current, recordingModel === model {
            current = nil
            removeObservers()
            (recording, session, incognito) = (running, recordingSession, recordingIncognito)
        } else if let index = leftovers.firstIndex(where: { $0.model === model }) {
            let leftover = leftovers.remove(at: index)
            (recording, session, incognito) = (leftover.recording, leftover.session, leftover.incognito)
        } else {
            return AgentPaneReply.success(["cancelled": true])
        }
        finishing = true
        defer { finished() }
        guard let made = await recording.finish(), let identity = made.identity else { return AgentPaneReply.success(["cancelled": true]) }
        let movie = URL(fileURLWithPath: made.path)
        let upload = model.chatUploadFolders?.freshUpload(session: session)
        let path = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
            (upload.flatMap { Self.keep(movie, in: $0, expected: identity) } ?? movie).path
        }.value
        written.insert(path)
        identities[path] = identity
        if quitting, !incognito { quitKept.append(URL(fileURLWithPath: path) as NSURL) }
        return AgentPaneReply.success(["path": path, "name": made.name, "seconds": made.seconds])
    }

    /// The quit (QuitCoordinator awaits it after the composers are saved, before the engines
    /// stop): the running recording and every one not collected end, their movies are finalized
    /// and moved into their chat's Chat Uploads folder, and their files go on the clipboard, so a
    /// quit never loses a clip. An incognito chat's is discarded with the chat, never kept or
    /// copied. The stream's stop is under ``AgentPaneRecording/callLimit``.
    func finishForQuit() async {
        quitting = true
        // A stop finalizing now: its movie first, so the process never ends under its writer.
        if finishing { await withCheckedContinuation { finishWaiters.append($0) } }
        var pending = leftovers.map { (recording: $0.recording, session: $0.session, model: $0.model, incognito: $0.incognito) }
        leftovers = []
        if let running = current {
            pending.append((running, recordingSession, recordingModel, recordingIncognito))
            current = nil
            removeObservers()
        }
        var kept = quitKept
        for item in pending {
            if item.incognito {
                await item.recording.discard()
                continue
            }
            guard let made = await item.recording.finish(), made.identity != nil else { continue }
            let movie = URL(fileURLWithPath: made.path)
            let upload = (item.model?.chatUploadFolders ?? ChatUploadFolders.standard)?.freshUpload(session: item.session)
            let moved = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
                upload.flatMap { Self.keep(movie, in: $0, expected: made.identity) }
            }.value
            kept.append((moved ?? movie) as NSURL)
        }
        guard !kept.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(kept)
    }

    /// Takes `recording` out of `current`: a leftover its pane may collect, or discarded with its pane gone.
    private func retire(_ recording: AgentPaneRecording) {
        current = nil
        if let owner = recordingModel {
            leftovers.append(Leftover(model: owner, session: recordingSession, incognito: recordingIncognito, recording: recording, since: Date()))
        } else {
            Task.detached(priority: .utility) { await recording.discard() }
        }
    }

    /// A stop is done finalizing: a quit waiting for it goes on.
    private func finished() {
        finishing = false
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// `window` and its child windows, all the way down: what a recording of it shows.
    static func family(_ window: NSWindow) -> Set<CGWindowID> {
        var ids: Set<CGWindowID> = []
        var pending = [window]
        while let next = pending.popLast() {
            if next.windowNumber > 0 { ids.insert(CGWindowID(next.windowNumber)) }
            pending.append(contentsOf: next.childWindows ?? [])
        }
        return ids
    }

    /// Discards the leftovers whose pane is gone (nobody can collect them any more) and those
    /// waiting over a day, as the sweep would (a pane that missed the end event never asks).
    private func dropOrphans() {
        let now = Date()
        let gone = { (leftover: Leftover) in leftover.model == nil || now.timeIntervalSince(leftover.since) > 24 * 60 * 60 }
        let orphans = leftovers.filter(gone).map(\.recording)
        leftovers.removeAll(where: gone)
        for orphan in orphans { Task.detached(priority: .utility) { await orphan.discard() } }
    }

    /// The screenshot just handed `model`'s page (its base64, as the page got it): its Copy or
    /// Save may take these bytes once. The decode and the hash run off the main actor.
    func handed(_ base64: String, to model: AgentPaneModel) async {
        let digest = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
            Data(base64Encoded: base64).map(Self.digest)
        }.value
        guard let digest else { return }
        shots.removeAll { $0.model == nil || $0.model === model }
        shots.append(Shot(model: model, digest: digest, at: Date()))
    }

    /// Whether `data` is `model`'s last screenshot; it is spent then.
    func takeShot(_ data: Data, for model: AgentPaneModel, now: Date = Date()) async -> Bool {
        let digest = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { Self.digest(data) }.value
        shots.removeAll { $0.model == nil || now.timeIntervalSince($0.at) > Self.shotLifetime }
        guard let index = shots.firstIndex(where: { $0.model === model && $0.digest == digest }) else { return false }
        shots.remove(at: index)
        return true
    }

    /// `model`'s page handled its last screenshot another way (the chat took it): its Copy and Save are spent.
    func spendShot(of model: AgentPaneModel) {
        shots.removeAll { $0.model == nil || $0.model === model }
    }

    nonisolated static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// `recording` runs for `model`'s page (`view`, the chat that hears when it ends).
    func began(_ recording: AgentPaneRecording, for model: AgentPaneModel, view: AgentPaneView?) {
        current = recording
        recordingView = view
        recordingModel = model
        recordingSession = model.onLocalPaths?() == true ? model.sessionId : nil
        recordingIncognito = model.sendIsIncognito?() ?? true
    }

    /// Whether a recording runs (and no other may start).
    var isRecording: Bool { current != nil }

    /// A recording ended by itself (on the main actor after it; a Stop took it out of `current`
    /// first): its observers go and it leaves `current` on every path, so the next Record is never
    /// refused. Its movie waits for its own pane's `capture.record.stop` as a leftover, or goes when
    /// its pane is gone; its chat's page, when there is one, hears `captureBar {ended: true}`.
    func ended(_ recording: AgentPaneRecording) {
        guard current === recording else { return }
        removeObservers()
        retire(recording)
        guard let view = recordingView else { return }
        let value: JSONValue = ["ended": .bool(true)]
        view.deliver([AgentPageEvent(kind: "captureBar", value: value)],
                     scripts: ["window.cmuxAcpmuxBridge?.captureBar?.(\(value.compactText));"])
    }

    /// `window`'s frame in global points from the top-left of the main display, as ScreenCaptureKit gives it.
    static func globalFrame(_ window: NSWindow) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
        return CGRect(x: window.frame.minX, y: top - window.frame.maxY, width: window.frame.width, height: window.frame.height)
    }

    /// The file at `path` when this bridge wrote it, with its identity then; nil otherwise.
    func owned(_ path: String) -> (url: URL, identity: FileIdentity)? {
        guard let identity = identities[path],
              let url = Self.owned(path, in: [Self.folder] + (ChatUploadFolders.standard.map { [$0.root] } ?? []), written: written) else { return nil }
        return (url, identity)
    }

    private func removeObservers() {
        observers.forEach { $0.cancel() }
        observers = []
    }
}

/// One recording: ScreenCaptureKit's stream of the window's display, showing only this app's
/// windows and cut to the window, into an AVAssetWriter. The stream's frames and the writer run on
/// `queue`; start and the end run off the main actor, each ScreenCaptureKit call under a deadline.
// crash-allow: `writer`, `input`, `adaptor`, `writerFailed` only on `queue` (frames, the close hops onto it); `output` set before the stream starts, then read; the rest in Mutexes.
nonisolated final class AgentPaneRecording: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated struct Options: Sendable {
        let window: CGWindowID
        let scale: Double
        let cursor: Bool
        let clicks: Bool
        let url: URL
        /// The window and its child windows (its pages' Chromium windows, its panels): the only
        /// windows the movie shows, never another cmux window that overlaps it.
        let windows: Set<CGWindowID>
    }

    /// The finished movie, as the page gets it.
    nonisolated struct Made: Sendable {
        let path: String
        let name: String
        let seconds: Double
        /// The movie file's identity when the writer finished: only that file is moved or handed out.
        let identity: AgentPaneRecorder.FileIdentity?
    }

    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    nonisolated struct State: Sendable {
        var ending = false
        var first: CMTime?
        var last: CMTime?
        /// The display filmed, in ScreenCaptureKit's global points (top-left origin), from the start.
        var display: CGRect?
        /// The window's newest frame not yet given to the stream, and whether an update runs.
        var moved: CGRect?
        var updating = false
    }

    /// Seconds any one ScreenCaptureKit call may take (a disconnected replayd never answers).
    static let callLimit: Duration = .seconds(10)

    private let options: Options
    /// The movie's pixel size, set once at the start before the stream runs, then only read.
    private var output = (width: 2, height: 2)
    private let queue = DispatchQueue(label: "agent-pane.capture.record", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// The writer could not open: no frame tries again, and the stop answers cancelled.
    private var writerFailed = false
    // concurrency-allow: held only to read or set the flags and times; no call out or I/O runs under it.
    let state = Mutex(State())
    // concurrency-allow: held only to put or take the stream; no ScreenCaptureKit call runs under it.
    let streamSlot = Mutex<Handed<SCStream>?>(nil)
    // concurrency-allow: held only to make or read the one end task; the task runs after the unlock.
    private let outcome = Mutex<Task<Made?, Never>?>(nil)
    private let limit = DemandTimer(owner: "agent-pane.capture.record.limit")

    /// Told once, on the queue that ends it, when the recording ends by any path.
    private let onEnd: @Sendable (AgentPaneRecording) -> Void

    init(_ options: Options, onEnd: @escaping @Sendable (AgentPaneRecording) -> Void = { _ in }) {
        self.options = options
        self.onEnd = onEnd
        super.init()
    }

    var isEnding: Bool { state.withLock { $0.ending } }

    /// The folder, ScreenCaptureKit's content list, the filter and the stream's start, off the main actor.
    @concurrent func start() async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description: "own-window capture needs macOS 14.4") }
        try FileManager.checked.createDirectory(at: options.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content: Handed<SCShareableContent> = try await deadline("list this process's windows") { done in
            SCShareableContent.getCurrentProcessShareableContent { content, error in
                done(content.map { .success(Handed($0)) } ?? .failure(error ?? Failure(description: "no shareable content")))
            }
        }
        guard let target = content.value.windows.first(where: { $0.windowID == options.window }) else {
            throw Failure(description: "ScreenCaptureKit lists no window \(options.window) of this process")
        }
        guard let display = content.value.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.value.displays.first else {
            throw Failure(description: "ScreenCaptureKit lists no display for this process")
        }
        // The display with only this window and its child windows (its pages' Chromium windows, its
        // panels), cut to the window: another cmux window over it, an incognito one too, never shows.
        let own = content.value.windows.filter { $0.isOnScreen && options.windows.contains($0.windowID) }
        let filter = SCContentFilter(display: display, including: own.isEmpty ? [target] : own)
        guard let source = Self.source(target.frame, on: display.frame) else { throw Failure(description: "the window is off its display") }
        // The movie's size is the window's at the start: a later resize scales into it (aspect-fit).
        output = AgentPaneRecorder.size(points: source.size, scale: options.scale)
        state.withLock { $0.display = display.frame }
        let stream = SCStream(filter: filter, configuration: configuration(source), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let _: Bool = try await deadline("start the capture") { done in
            stream.startCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
        }
        // Store first, then look at `ending`: an end in between found no stream, so this side
        // stops it; an end after the store stops it itself. Exactly one side stops the stream.
        streamSlot.withLock { $0 = Handed(stream) }
        if isEnding, let mine = streamSlot.withLock({ slot -> Handed<SCStream>? in defer { slot = nil }; return slot }) {
            _ = try? await stop(mine.value)
            return
        }
        limit.schedule(after: .seconds(AgentPaneRecorder.maxSeconds)) { [weak self] in self?.end() }
    }

    func configuration(_ source: CGRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        configuration.width = output.width
        configuration.height = output.height
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: AgentPaneRecorder.framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 6
        configuration.showsCursor = options.cursor
        if #available(macOS 15.0, *) { configuration.showMouseClicks = options.clicks }
        return configuration
    }

    /// The name of the recording's own folder in ``AgentPaneRecorder/folder``.
    var folderName: String { options.url.deletingLastPathComponent().lastPathComponent }

    /// Ends the recording once (any thread, at once); ``finish()`` waits for the movie.
    func end() { _ = ending() }

    /// Ends the recording once and returns its movie, nil when it has no frame or did not write.
    func finish() async -> Made? { await ending().value }

    /// Ends it and removes its folder: a movie nobody was given.
    func discard() async {
        _ = await finish()
        try? FileManager.checked.removeItem(at: options.url.deletingLastPathComponent())
    }

    private func ending() -> Task<Made?, Never> {
        let (task, first) = outcome.withLock { slot -> (Task<Made?, Never>, Bool) in
            if let task = slot { return (task, false) }
            state.withLock { $0.ending = true }
            let task = Task.detached(priority: .userInitiated) { [self] in await close() }
            slot = task
            return (task, true)
        }
        if first { onEnd(self) }
        return task
    }

    /// Closes the movie on `queue` while the stream stops beside it; a recording with no movie leaves no folder.
    private func close() async -> Made? {
        limit.cancel()
        // The movie is finished first, never after the stream's stop: frames that still come are
        // dropped (`isEnding`), and a stop ScreenCaptureKit is slow to answer (up to `callLimit`)
        // runs beside it, so a quit's deadline never cuts the movie off unfinished.
        if let handed = streamSlot.withLock({ slot -> Handed<SCStream>? in defer { slot = nil }; return slot }) {
            Task.detached(priority: .userInitiated) { [self] in _ = try? await stop(handed.value) }
        }
        let stoppedAt = CMClockGetTime(CMClockGetHostTimeClock())
        let made = await withCheckedContinuation { (done: CheckedContinuation<Made?, Never>) in
            queue.async { [self] in closeMovie(at: stoppedAt) { done.resume(returning: $0) } }
        }
        if made == nil { try? FileManager.checked.removeItem(at: options.url.deletingLastPathComponent()) }
        return made
    }

    /// On `queue`: the movie's end, at the stop when nothing changed on screen since the last frame.
    private func closeMovie(at stoppedAt: CMTime, _ done: @escaping @Sendable (Made?) -> Void) {
        let times = state.withLock { $0 }
        guard let writer, let input, writer.status == .writing, let first = times.first, let last = times.last else {
            if writer?.status == .writing { writer?.cancelWriting() }
            return done(nil)
        }
        let cap = CMTimeAdd(first, CMTime(value: CMTimeValue(AgentPaneRecorder.maxSeconds + 1), timescale: 1))
        let end = CMTimeMinimum(CMTimeMaximum(last, stoppedAt), cap)
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        let url = options.url
        let seconds = (CMTimeSubtract(end, first).seconds * 10).rounded() / 10
        let held = Handed(writer)
        writer.finishWriting {
            guard held.value.status == .completed else { return done(nil) }
            // The path as this recorder made it, never resolved through links: a link put in the
            // folder's place is never followed to another file.
            done(Made(path: url.path, name: url.lastPathComponent, seconds: seconds, identity: AgentPaneRecorder.identity(url.path)))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), !isEnding else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil, !writerFailed { openWriter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), at: time) }
        guard let input, let adaptor, input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) else { return }
        state.withLock { state in
            if state.first == nil { state.first = time }
            state.last = time
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { end() }

    /// On `queue`, at the first frame: the H.264 writer at that frame's size, its session from that frame.
    private func openWriter(width: Int, height: Int, at time: CMTime) {
        writerFailed = true
        guard let writer = try? AVAssetWriter(outputURL: options.url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, max(6_000_000, width * height * 5)),
                AVVideoExpectedSourceFrameRateKey: AgentPaneRecorder.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: Int(AgentPaneRecorder.framesPerSecond) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        // The adaptor must exist before startWriting (AVFoundation raises for one made after).
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: time)
        (self.writer, self.input, self.adaptor, writerFailed) = (writer, input, adaptor, false)
    }

    private func stop(_ stream: SCStream) async throws {
        let _: Bool = try await deadline("stop the capture") { done in
            stream.stopCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
        }
    }

    /// A ScreenCaptureKit object handed across its callback queue once.
    // crash-allow: ScreenCaptureKit makes the value and never touches it again; one side reads it after the hand-over.
    nonisolated struct Handed<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
