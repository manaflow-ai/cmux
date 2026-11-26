#if os(iOS) && DEBUG
import CmuxMobileLinkFFI
import Foundation
import Observation

/// DEBUG only, for `-cmux-mobile-demo ws-terminal-cancel-send`
/// (TerminalCancelMidSendUITests): an upload queue with no Mac behind it whose
/// bytes move at a fixed pace, so Stop lands partway through a large video.
/// Each upload runs `duration` seconds end to end, ticking progress every
/// 100 ms, and keeps going after Stop as the live engine does (cancelSend
/// calls off the send, not the upload).
@MainActor
@Observable
public final class DemoSlowAttachmentSender: TerminalAttachmentSending {
    private var states: [String: UploadProgress] = [:]
    @ObservationIgnored private var tickers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<String, any Error>]] = [:]
    @ObservationIgnored private let duration: TimeInterval

    public init(duration: TimeInterval) {
        self.duration = duration
    }

    public func start(_ attachment: ComposerAttachment) -> String? {
        let id = UUID().uuidString
        let total = UInt64(max(1, attachment.byteCount ?? 1))
        states[id] = UploadProgress(uploadId: id, stage: .uploading, ackedBytes: 0, sentBytes: 0, totalBytes: total,
                                    attempt: 1, macPath: nil, errorCode: nil, errorMessage: nil)
        let steps = max(1, Int(duration * 10))
        tickers[id] = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                let acked = total * UInt64(step) / UInt64(steps)
                self.states[id]?.ackedBytes = acked
                self.states[id]?.sentBytes = acked
            }
            self?.finish(id, path: "/tmp/cmux-uploads/\(attachment.name)")
        }
        return id
    }

    public func cancel(_ uploadID: String) {
        tickers.removeValue(forKey: uploadID)?.cancel()
        states[uploadID]?.stage = .cancelled
        for waiter in waiters.removeValue(forKey: uploadID) ?? [] { waiter.resume(throwing: CancellationError()) }
    }

    public func wait(_ uploadID: String) async throws -> String {
        if let state = states[uploadID] {
            if state.stage == .done, let path = state.macPath { return path }
            if state.stage == .cancelled { throw CancellationError() }
        }
        return try await withCheckedThrowingContinuation { waiters[uploadID, default: []].append($0) }
    }

    public func progress(_ uploadID: String) -> UploadProgress? {
        states[uploadID]
    }

    private func finish(_ id: String, path: String) {
        tickers[id] = nil
        states[id]?.stage = .done
        states[id]?.macPath = path
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: path) }
    }
}

extension TerminalModel {
    /// `ws-terminal-cancel-send`: a draft with a large video in the tray,
    /// carried by the slow demo queue (its bytes take `seconds` to move).
    public func demoSlowVideoSend(seconds: TimeInterval) {
        attachmentSender = DemoSlowAttachmentSender(duration: seconds)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demo-cancel-send-clip.mov")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0, count: 4096))
        }
        composerText = "What happens in this clip?"
        addAttachment(ComposerAttachment(kind: .video, name: "Clip.mov", byteCount: 412_000_000, fileURL: file))
    }
}
#endif
