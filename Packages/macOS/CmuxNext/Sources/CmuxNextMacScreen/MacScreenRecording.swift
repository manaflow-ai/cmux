import AppKit
import CmuxNextCompat
public import Foundation
import CmuxNextRemoteView
import CmuxNextWakeups
public import Observation

/// Recording as you go: the toolbar's Record button. The Rust core copies
/// every frame the viewer receives into an MP4 (no re-encoding) at
/// `~/Movies/cmux/<device>-<UTC time>.mp4`; each fragment is written as it
/// arrives, so a crash leaves a playable file. A new stream (a reconnect, a
/// quality change) ends the recording; Record starts a new file.
@MainActor
@Observable
public final class MacScreenRecording {
    /// The file being written; nil when not recording (internal set: the viewer gallery draws a recording).
    public internal(set) var file: URL?
    /// When the file being written was started; nil when not recording (the elapsed-time mark).
    public internal(set) var startedAt: Date?
    /// The newest finished file (Show in Finder).
    public private(set) var lastFile: URL?
    /// The last recording could not be created or written.
    public private(set) var failed = false
    @ObservationIgnored private var transport: RemoteRdStreamTransport?

    public init() {}

    public var isRecording: Bool { file != nil }
    /// A stream is up to record.
    public var canRecord: Bool { transport != nil }

    /// A new stream: its session starts without a recording (the old one's
    /// file was closed with its session).
    func attach(_ transport: RemoteRdStreamTransport?) {
        self.transport = transport
        if let file {
            lastFile = file
            self.file = nil
            startedAt = nil
        }
    }

    func toggle(device: String) {
        if isRecording { stop() } else { start(device: device) }
    }

    func start(device: String) {
        guard let transport, file == nil else { return }
        let url = Self.fileURL(device: device, at: Date())
        file = url
        startedAt = Date()
        failed = false
        transport.startRecording(to: url) { ok in
            guard !ok else { return }
            MainDelivery().run { [weak self] in
                guard let self, file == url else { return }
                file = nil
                startedAt = nil
                failed = true
            }
        }
    }

    func stop() {
        guard let url = file else { return }
        file = nil
        startedAt = nil
        lastFile = url
        transport?.stopRecording { frames in
            guard frames == nil else { return }
            MainDelivery().run { [weak self] in self?.failed = true }
        }
    }

    func showInFinder() {
        guard let url = file ?? lastFile else { return }
        NSWorkspace.shared.revealInBackground([url])
    }

    /// `~/Movies/cmux/<device>-<yyyy-MM-dd'T'HHmmss'Z'>.mp4` (the device name
    /// without path separators).
    nonisolated static func fileURL(device: String, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        let name = device.map { "/:\\".contains($0) ? "-" : $0 }
        let base = String(name).trimmingCharacters(in: .whitespacesAndNewlines)
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("\(base.isEmpty ? "screen" : base)-\(formatter.string(from: date)).mp4")
    }
}
