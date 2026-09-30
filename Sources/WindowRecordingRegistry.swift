import CmuxFoundation
import CoreGraphics
import Foundation

/// Owns the one recording cmux may have in flight, and remembers the last few
/// that finished so an agent can still ask where the file went.
///
/// One at a time on purpose: two recorders sampling the same window would each
/// see the other's frame rate collapse, and the interesting failure ("I started
/// a second clip and both are half speed") is much harder to read than an error.
actor WindowRecordingRegistry {
    static let shared = WindowRecordingRegistry()

    private static let historyLimit = 8

    private var active: WindowRecordingSession?
    /// The `record start` call that claimed `active`, so a caller that timed
    /// out can end exactly the session it opened and nothing newer.
    private var activeStartToken: UUID?
    /// Starts still running, and those whose caller has already given up.
    private var registeredStarts: Set<UUID> = []
    private var pendingStarts: Set<UUID> = []
    private var history: [WindowRecordingStatus] = []

    enum Failure: Error, LocalizedError {
        case busy(String)
        case noRecording
        case unknownRecording(String)
        case alreadyStopped(String)

        var errorDescription: String? {
            switch self {
            case let .busy(id):
                "a recording is already running (\(id)); stop it first"
            case .noRecording:
                "no recording is running"
            case let .unknownRecording(id):
                "no recording with id \(id)"
            case let .alreadyStopped(id):
                "recording \(id) already stopped"
            }
        }
    }

    /// Registers a start token before the socket worker launches the operation.
    /// This closes the gap where a timeout could be observed before `start`
    /// first entered this actor.
    func registerStart(token: UUID) {
        registeredStarts.insert(token)
    }

    func start(
        request: WindowRecordingRequest,
        windowID: CGWindowID,
        windowHandle: String?,
        token: UUID = UUID()
    ) async throws -> WindowRecordingStatus {
        guard registeredStarts.remove(token) != nil else {
            throw WindowRecordingSessionError.alreadyFinished
        }
        pendingStarts.insert(token)
        defer {
            pendingStarts.remove(token)
        }
        await harvestFinishedRecording()
        if let active {
            throw Failure.busy(active.id)
        }
        let identifier = WindowRecordingRequest.recordingIdentifier(date: Date())
        let session = WindowRecordingSession(
            id: identifier,
            request: request,
            outputURL: Self.outputURL(request: request, identifier: identifier),
            windowID: windowID,
            windowHandle: windowHandle
        )
        // Claim the slot before the first await: opening a recording takes a
        // capture round trip, and a second `record start` arriving during it
        // would otherwise pass the check above and replace this session.
        active = session
        activeStartToken = token
        do {
            try await session.start()
        } catch {
            releaseSlot(held: session)
            throw error
        }
        // `abandonStart` may have ended the session during the await above.
        guard await session.isRecording else {
            releaseSlot(held: session)
            throw WindowRecordingSessionError.alreadyFinished
        }
        return await session.status
    }

    /// Called when the socket caller of `start(token:)` stopped waiting. The
    /// caller was told the start failed, so the session it would have opened
    /// must not keep recording: end and discard it, or make a start that has
    /// not claimed the slot yet give up when it gets there. Returns once the
    /// session has released its writer and partial file.
    func abandonStart(token: UUID) async {
        if registeredStarts.remove(token) != nil { return }
        guard pendingStarts.contains(token) || activeStartToken == token else { return }
        guard let session = active, activeStartToken == token else {
            return
        }
        await session.abandon(reason: "record start timed out; the recording was discarded")
        remember(await session.status)
        releaseSlot(held: session)
    }

    private func releaseSlot(held session: WindowRecordingSession) {
        guard active === session else { return }
        active = nil
        activeStartToken = nil
    }

    func stop(id: String?) async throws -> WindowRecordingStatus {
        await harvestFinishedRecording()
        if let active, id == nil || id == active.id {
            let status = await active.stop()
            releaseSlot(held: active)
            remember(status)
            return status
        }
        guard let id else {
            // A clip that reached its own `--max-seconds` limit has already
            // closed its file, so report it rather than claiming nothing ran.
            guard let latest = history.last else { throw Failure.noRecording }
            return latest
        }
        guard let remembered = history.last(where: { $0.id == id }) else {
            throw Failure.unknownRecording(id)
        }
        return remembered
    }

    func status(id: String?) async throws -> WindowRecordingStatus {
        await harvestFinishedRecording()
        if let active, id == nil || id == active.id {
            return await active.status
        }
        guard let id else {
            guard let latest = history.last else { throw Failure.noRecording }
            return latest
        }
        guard let remembered = history.last(where: { $0.id == id }) else {
            throw Failure.unknownRecording(id)
        }
        return remembered
    }

    /// Adds a caption to the running clip. Captions are what make a clip
    /// readable in a pull request: an agent labels each step as it takes it.
    func note(text: String, id: String?) async throws -> WindowRecordingStatus {
        await harvestFinishedRecording()
        guard let active, id == nil || id == active.id else {
            guard let id else { throw Failure.noRecording }
            if history.contains(where: { $0.id == id }) {
                throw Failure.alreadyStopped(id)
            }
            throw Failure.unknownRecording(id)
        }
        _ = await active.note(text)
        return await active.status
    }

    func recentStatuses() async -> [WindowRecordingStatus] {
        await harvestFinishedRecording()
        var statuses = history
        if let active {
            statuses.append(await active.status)
        }
        return statuses
    }

    /// A recording that reached its own frame or time limit has already closed
    /// its file; move it into history the next time anyone asks.
    private func harvestFinishedRecording() async {
        guard let active else { return }
        let isRecording = await active.isRecording
        guard !isRecording else { return }
        remember(await active.status)
        releaseSlot(held: active)
    }

    /// Files a finished clip in history. Internal rather than private so tests
    /// can set up a registry without a window on screen.
    func remember(_ status: WindowRecordingStatus) {
        history.removeAll { $0.id == status.id }
        history.append(status)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    private static func outputURL(
        request: WindowRecordingRequest,
        identifier: String
    ) -> URL {
        if let outputPath = request.outputPath {
            return URL(fileURLWithPath: outputPath)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(WindowRecordingRequest.outputDirectoryName)
            .appendingPathComponent(request.outputFilename(identifier: identifier))
    }
}
