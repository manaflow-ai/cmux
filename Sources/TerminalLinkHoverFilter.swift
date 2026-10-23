import AppKit
import CmuxTerminal
import CmuxTerminalCore
import Foundation
import os

/// Answers Ghostty's link filter for one surface (cx-do47.1). A regex match
/// under the pointer is a link only when it names a file or folder that exists
/// (against the terminal's directory, then the git root above it) or a web
/// address cmux would open, so `missing/nowhere.md` gets no underline, no
/// pointing hand and no click. Remote terminals keep Ghostty's answer: their
/// paths name files on another machine.
///
/// Ghostty asks on the main thread while the pointer moves, holding the
/// terminal lock, and again on the renderer thread. The main thread answers at
/// once and caches the answer; the renderer thread answers from the cache, and
/// a miss resolves on the main thread and re-sends the pointer so Ghostty asks
/// again.
final class TerminalLinkHoverFilter: @unchecked Sendable {
    private struct Answer: Sendable {
        let isLink: Bool
        let cwd: String?
        let time: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var answers: [String: Answer] = [:]
        var pending: Set<String> = []
    }

    private static let lifetime: Duration = .seconds(3)
    private static let capacity = 512

    let surfaceID: UUID
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(surfaceID: UUID) {
        self.surfaceID = surfaceID
    }

    /// Whether `text`, the match under the pointer, is a link.
    func accepts(_ text: String) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { answerOnMain(text) }
        }
        let now = ContinuousClock.now
        let (cached, schedule) = state.withLock { state -> (Answer?, Bool) in
            let cached = state.answers[text]
            guard cached.map({ now - $0.time > Self.lifetime }) ?? true else { return (cached, false) }
            return (cached, state.pending.insert(text).inserted)
        }
        if schedule {
            DispatchQueue.main.async { [self] in
                let before = cached?.isLink
                let after = answerOnMain(text)
                state.withLock { _ = $0.pending.remove(text) }
                if before != after { refreshPointer() }
            }
        }
        return cached?.isLink ?? false
    }

    @MainActor
    private func answerOnMain(_ text: String) -> Bool {
        guard let surface = GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceID) as? TerminalSurface,
              let workspace = surface.owningWorkspace(),
              workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: surfaceID) else {
            return true
        }
        let cwd = CommandClickFileOpenRouter.resolveWorkingDirectory(workspace: workspace, surfaceId: surfaceID)
        let now = ContinuousClock.now
        if let cached = state.withLock({ $0.answers[text] }), cached.cwd == cwd, now - cached.time <= Self.lifetime {
            return cached.isLink
        }
        let isLink = Self.isLink(text, cwd: cwd)
        state.withLock { state in
            if state.answers.count >= Self.capacity { state.answers.removeAll(keepingCapacity: true) }
            state.answers[text] = Answer(isLink: isLink, cwd: cwd, time: now)
        }
        return isLink
    }

    /// Re-sends the pointer so Ghostty asks again after an answer changed.
    @MainActor
    private func refreshPointer() {
        (GhosttyApp.terminalSurfaceRegistry.surface(id: surfaceID) as? TerminalSurface)?
            .hostedView.surfaceView.refreshLinkHover()
    }

    /// A file or folder that exists, or a URL that is not a file: the same
    /// targets a Cmd-click opens.
    static func isLink(_ text: String, cwd: String?) -> Bool {
        if TerminalPathResolver().resolveOpenURLFileReference(text, cwd: cwd) != nil { return true }
        guard let target = resolveTerminalOpenURLTarget(text) else { return false }
        return !target.url.isFileURL
    }
}

/// Ghostty's link filter callback; `userdata` is the surface's retained
/// ``TerminalLinkHoverFilter``.
let cmuxTerminalLinkFilterCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt
) -> Bool = { userdata, text, length in
    guard let userdata, let text else { return true }
    let filter = Unmanaged<TerminalLinkHoverFilter>.fromOpaque(userdata).takeUnretainedValue()
    let bytes = UnsafeRawBufferPointer(start: text, count: Int(length))
    return filter.accepts(String(decoding: bytes, as: UTF8.self))
}
