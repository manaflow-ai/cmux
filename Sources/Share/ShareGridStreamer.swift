import CMUXMobileCore
import CmuxTerminal
import CmuxWorkspaceShare
import Foundation
import os

nonisolated private let shareTerminalStreamerLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "WorkspaceShareTerminal"
)

/// Streams one authoritative terminal byte stream per subscribed pane.
///
/// A complete synthesized VT baseline gives xterm a cold-attach state. Every
/// subsequent output frame is the exact PTY byte sequence observed by the Mac.
/// Sequence gaps, runtime replacement, geometry changes, theme changes, and
/// alternate-screen transitions all force a new baseline and epoch.
@MainActor
final class ShareGridStreamer {
    /// Canonical `CMXS` frame ready for the bounded share socket mailbox.
    var sendBinary: ((Data) -> Bool)?

    private struct RenderSignature: Equatable {
        let runtimeGeneration: UInt64
        let rows: Int
        let columns: Int
        let activeScreen: MobileTerminalRenderGridFrame.Screen
    }

    private final class PaneStream {
        var workspaceID: String
        var subscriberCount: Int
        var streamEpoch = UUID()
        var nextSequence: UInt64?
        var renderSignature: RenderSignature?
        var needsBaseline = true
        var outputTaskID = UUID()
        var outputTask: Task<Void, Never>?

        init(workspaceID: String, subscriberCount: Int) {
            self.workspaceID = workspaceID
            self.subscriberCount = subscriberCount
        }
    }

    private static let baselineScrollbackBudgets = [
        1_000, 500, 250, 125, 64, 32, 16, 8, 0,
    ]
    private static let maximumOutputPayloadBytes = 64 * 1_024

    /// Keyed by `TerminalSurface.id`.
    private var streamsBySurfaceID: [UUID: PaneStream] = [:]
    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pendingSurfaceIDs = Set<UUID>()
    private var hasPendingGlobalUpdate = false
    private var isFlushScheduled = false
    private var flushTask: Task<Void, Never>?

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let view = notification.object as? GhosttyNSView,
                      let surfaceID = view.terminalSurface?.id else {
                    return
                }
                self?.enqueueUpdate(surfaceID: surfaceID)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                MobileTerminalByteTee.shared.noteRawOutputPostParseTick()
                self?.enqueueUpdate(surfaceID: nil)
            }
        })
        for name in [
            Notification.Name.ghosttyDefaultBackgroundDidChange,
            .ghosttyConfigDidReload,
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.requestBaselinesForAllPanes()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let surfaceID = notification.object as? UUID else {
                    return
                }
                self?.requestBaseline(surfaceID: surfaceID)
            }
        })
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for stream in streamsBySurfaceID.values {
            stream.outputTask?.cancel()
        }
        streamsBySurfaceID.removeAll()
        refreshNotificationDemand()
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalUpdate = false
        isFlushScheduled = false
        flushTask?.cancel()
        flushTask = nil
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseFrameDemand?()
        releaseTickDemand?()
        flushTask?.cancel()
        for stream in streamsBySurfaceID.values {
            stream.outputTask?.cancel()
        }
    }

    /// Applies the authoritative aggregate count from `guest-sub`.
    ///
    /// An increased count emits a replacement baseline because a newly
    /// subscribed guest cannot safely begin in the middle of an output stream.
    func setSubscriberCount(ws: String, pane: String, count: Int) {
        guard let surfaceID = UUID(uuidString: pane) else { return }
        let previousCount = streamsBySurfaceID[surfaceID]?.subscriberCount ?? 0
        if count <= 0 {
            streamsBySurfaceID.removeValue(forKey: surfaceID)?.outputTask?.cancel()
            pendingSurfaceIDs.remove(surfaceID)
            refreshNotificationDemand()
            return
        }

        let stream: PaneStream
        if let existing = streamsBySurfaceID[surfaceID] {
            stream = existing
            stream.workspaceID = ws
            stream.subscriberCount = count
        } else {
            stream = PaneStream(workspaceID: ws, subscriberCount: count)
            streamsBySurfaceID[surfaceID] = stream
        }
        startOutputTaskIfNeeded(surfaceID: surfaceID, stream: stream)
        refreshNotificationDemand()
        if count > previousCount {
            requestBaseline(surfaceID: surfaceID)
        }
    }

    /// Replaces every subscribed xterm after a socket or Durable Object resync.
    func resendFullFrames() {
        requestBaselinesForAllPanes()
    }

    /// Replaces one currently subscribed xterm after that guest detected a
    /// sequence gap or remounted its parser.
    @discardableResult
    func resendFullFrame(ws: String, pane: String) -> Bool {
        guard let surfaceID = UUID(uuidString: pane),
              let stream = streamsBySurfaceID[surfaceID],
              stream.workspaceID == ws,
              stream.subscriberCount > 0 else {
            return false
        }
        requestBaseline(surfaceID: surfaceID)
        return true
    }

    private var hasSubscribers: Bool {
        !streamsBySurfaceID.isEmpty
    }

    private func refreshNotificationDemand() {
        if hasSubscribers {
            if releaseFrameDemand == nil {
                releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
            }
            if releaseTickDemand == nil {
                releaseTickDemand = GhosttyApp.retainTickNotifications()
            }
        } else {
            releaseFrameDemand?()
            releaseFrameDemand = nil
            releaseTickDemand?()
            releaseTickDemand = nil
        }
    }

    private func startOutputTaskIfNeeded(
        surfaceID: UUID,
        stream: PaneStream
    ) {
        guard stream.outputTask == nil,
              GhosttyApp.terminalSurfaceRegistry.terminalSurface(
                id: surfaceID
              ) != nil else {
            return
        }
        let updates = MobileTerminalByteTee.shared.outputUpdates(
            surfaceID: surfaceID
        )
        let taskID = UUID()
        stream.outputTaskID = taskID
        stream.outputTask = Task { @MainActor [weak self] in
            for await chunk in updates {
                guard !Task.isCancelled else { return }
                self?.receiveOutput(
                    chunk,
                    surfaceID: surfaceID,
                    taskID: taskID
                )
            }
            guard !Task.isCancelled else { return }
            self?.outputTaskEnded(surfaceID: surfaceID, taskID: taskID)
        }
    }

    private func outputTaskEnded(surfaceID: UUID, taskID: UUID) {
        guard let stream = streamsBySurfaceID[surfaceID],
              stream.outputTaskID == taskID else {
            return
        }
        stream.outputTask = nil
        requestBaseline(surfaceID: surfaceID)
        startOutputTaskIfNeeded(surfaceID: surfaceID, stream: stream)
    }

    private func receiveOutput(
        _ chunk: MobileTerminalByteTee.OutputChunk,
        surfaceID: UUID,
        taskID: UUID
    ) {
        guard let stream = streamsBySurfaceID[surfaceID],
              stream.outputTaskID == taskID,
              !chunk.data.isEmpty else {
            return
        }
        guard !stream.needsBaseline, let expected = stream.nextSequence else {
            // The next post-parser tick captures these bytes in the baseline.
            GhosttyApp.shared.scheduleTick()
            return
        }
        let (chunkEnd, overflow) = chunk.sequence.addingReportingOverflow(
            UInt64(chunk.data.count)
        )
        guard !overflow else {
            requestBaseline(surfaceID: surfaceID)
            return
        }
        if chunkEnd <= expected {
            return
        }
        guard chunk.sequence <= expected else {
            requestBaseline(surfaceID: surfaceID)
            return
        }
        let offset = Int(expected - chunk.sequence)
        sendOutput(
            Data(chunk.data.dropFirst(offset)),
            startingAt: expected,
            surfaceID: surfaceID,
            stream: stream
        )
    }

    private func sendOutput(
        _ data: Data,
        startingAt start: UInt64,
        surfaceID: UUID,
        stream: PaneStream
    ) {
        var offset = 0
        var sequence = start
        while offset < data.count {
            let count = min(
                Self.maximumOutputPayloadBytes,
                data.count - offset
            )
            let payload = Data(data[offset..<(offset + count)])
            let (end, overflow) = sequence.addingReportingOverflow(
                UInt64(count)
            )
            guard !overflow,
                  let frame = try? WorkspaceShareTerminalFrame(
                      kind: .output,
                      streamEpoch: stream.streamEpoch,
                      sequenceStart: sequence,
                      sequenceEnd: end,
                      rows: 0,
                      columns: 0,
                      workspaceID: stream.workspaceID,
                      paneID: surfaceID.uuidString,
                      userID: nil,
                      bytes: payload
                  ),
                  let encoded = try? frame.encoded(),
                  sendBinary?(encoded) == true else {
                requestBaseline(surfaceID: surfaceID)
                shareTerminalStreamerLogger.warning(
                    "Raw terminal output was rejected before transport admission"
                )
                return
            }
            stream.nextSequence = end
            sequence = end
            offset += count
        }
    }

    private func requestBaselinesForAllPanes() {
        guard hasSubscribers else { return }
        for surfaceID in streamsBySurfaceID.keys {
            markBaselineNeeded(surfaceID: surfaceID)
        }
        GhosttyApp.shared.scheduleTick()
    }

    private func requestBaseline(surfaceID: UUID) {
        guard streamsBySurfaceID[surfaceID] != nil else { return }
        markBaselineNeeded(surfaceID: surfaceID)
        GhosttyApp.shared.scheduleTick()
    }

    private func markBaselineNeeded(surfaceID: UUID) {
        guard let stream = streamsBySurfaceID[surfaceID] else { return }
        stream.needsBaseline = true
        stream.nextSequence = nil
        pendingSurfaceIDs.insert(surfaceID)
    }

    private func enqueueUpdate(surfaceID: UUID?) {
        guard hasSubscribers else { return }
        if let surfaceID {
            guard streamsBySurfaceID[surfaceID] != nil else { return }
            pendingSurfaceIDs.insert(surfaceID)
        } else {
            hasPendingGlobalUpdate = true
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        flushTask = Task { @MainActor [weak self] in
            self?.flushUpdates()
        }
    }

    private func flushUpdates() {
        flushTask = nil
        isFlushScheduled = false
        guard hasSubscribers else { return }
        let surfaceIDs = hasPendingGlobalUpdate
            ? Set(streamsBySurfaceID.keys)
            : pendingSurfaceIDs
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalUpdate = false
        for surfaceID in surfaceIDs {
            inspectAndReconcile(surfaceID: surfaceID)
        }
    }

    private func inspectAndReconcile(surfaceID: UUID) {
        guard let stream = streamsBySurfaceID[surfaceID] else { return }
        startOutputTaskIfNeeded(surfaceID: surfaceID, stream: stream)
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(
            id: surfaceID
        ), surface.surface != nil else {
            stream.outputTask?.cancel()
            stream.outputTask = nil
            markBaselineNeeded(surfaceID: surfaceID)
            return
        }
        guard let inspection = surface.mobileRenderGridFrame(
            stateSeq: 0,
            full: true,
            scrollbackLines: 0,
            includeTheme: false
        ) else {
            markBaselineNeeded(surfaceID: surfaceID)
            return
        }
        let signature = RenderSignature(
            runtimeGeneration: surface.runtimeSurfaceGeneration,
            rows: inspection.frame.rows,
            columns: inspection.frame.columns,
            activeScreen: inspection.frame.activeScreen
        )
        if stream.renderSignature != nil,
           stream.renderSignature != signature {
            markBaselineNeeded(surfaceID: surfaceID)
        }
        if stream.needsBaseline {
            guard let stateSequence =
                MobileTerminalByteTee.shared.rawOutputBaselineSequenceIfReady(
                    surfaceID: surfaceID
                ) else {
                return
            }
            emitBaseline(
                surfaceID: surfaceID,
                surface: surface,
                stateSequence: stateSequence,
                signature: signature,
                stream: stream
            )
        } else {
            stream.renderSignature = signature
        }
    }

    private func emitBaseline(
        surfaceID: UUID,
        surface: TerminalSurface,
        stateSequence: UInt64,
        signature: RenderSignature,
        stream: PaneStream
    ) {
        let epoch = UUID()
        for scrollbackLines in Self.baselineScrollbackBudgets {
            guard let captured = surface.mobileRenderGridFrame(
                stateSeq: stateSequence,
                renderEpoch: epoch.uuidString,
                renderRevision: 1,
                full: true,
                scrollbackLines: scrollbackLines,
                includeTheme: true
            ) else {
                continue
            }
            let frame = captured.frame
            guard let rows = UInt16(exactly: frame.rows),
                  let columns = UInt16(exactly: frame.columns) else {
                break
            }
            let configTheme = (
                frame.terminalConfigTheme
                    ?? frame.terminalTheme
                    ?? .monokai
            ).validatedOrDefault()
            var bytes: Data
            do {
                bytes = try configTheme.xtermConfigurationPreambleBytes()
            } catch {
                continue
            }
            bytes.append(frame.vtPatchBytes())
            // A PTY callback may have begun on the IO thread while the main
            // actor exported this snapshot. Only publish when the barrier and
            // byte cursor are unchanged across the capture.
            guard MobileTerminalByteTee.shared
                .rawOutputBaselineSequenceIfReady(surfaceID: surfaceID)
                == stateSequence else {
                markBaselineNeeded(surfaceID: surfaceID)
                return
            }
            guard let terminalFrame = try? WorkspaceShareTerminalFrame(
                kind: .baseline,
                streamEpoch: epoch,
                sequenceStart: stateSequence,
                sequenceEnd: stateSequence,
                rows: rows,
                columns: columns,
                workspaceID: stream.workspaceID,
                paneID: surfaceID.uuidString,
                userID: nil,
                bytes: bytes
            ), let encoded = try? terminalFrame.encoded() else {
                continue
            }
            guard sendBinary?(encoded) == true else {
                markBaselineNeeded(surfaceID: surfaceID)
                shareTerminalStreamerLogger.warning(
                    "Terminal baseline was rejected before transport admission"
                )
                return
            }
            stream.streamEpoch = epoch
            stream.nextSequence = stateSequence
            stream.renderSignature = signature
            stream.needsBaseline = false
            #if DEBUG
            cmuxDebugLog(
                "share.terminal_baseline surface=\(surfaceID.uuidString.prefix(8)) " +
                    "seq=\(stateSequence) rows=\(rows) cols=\(columns) " +
                    "scrollback=\(scrollbackLines) bytes=\(bytes.count)"
            )
            #endif
            return
        }
        markBaselineNeeded(surfaceID: surfaceID)
        shareTerminalStreamerLogger.error(
            "No bounded terminal baseline could be encoded"
        )
    }
}
