import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What each tab's composer holds (a terminal's or an agent chat's), on disk by Mac and tab id.
///
/// A draft outlives everything but its own send: a reconnect that rebuilds the terminal, a view
/// rebuild, a tab switch, the app in the background or killed there (Leo, 2026-11-21: "the
/// connection f***ing lagged ... and my drafted message on ios in the f***ing round composer got
/// lost"). The composer writes what it holds as it changes; an empty composer (a send) removes it.
/// Writes wait a moment and go as one, and go at once when the app leaves the foreground.
/// A removal (the draft's send) goes at once: a kill inside the wait left the sent text on disk,
/// and the next launch put it back in the composer as if it were never sent (the LaunchTTI
/// bench's second launch typed `~` after a restored `~`, sent `~~`, and never saw its echo).
/// Encoding and the file write run on `writer`, never on the main thread: a write every 400 ms
/// while typing held the main thread for the encode and an atomic, protected file write (Leo,
/// 2026-11-22: "some weird hitch in the app at some strange intervals").
@MainActor
public final class ComposerDraftStore {
    public static let shared = ComposerDraftStore(url: ComposerDraftStore.defaultURL)

    struct Entry: Codable, Equatable, Sendable {
        var text: String
        var savedAt: Date
    }

    /// The most drafts kept (the oldest go first).
    static let limit = 200
    /// A draft left this long is gone with its tab (a Mac reuses a closed terminal's id later).
    static let maxAge: TimeInterval = 14 * 24 * 3600

    /// nil keeps the drafts in memory (tests, sample data).
    public let url: URL?
    private var drafts: [String: Entry]
    private let writeDelay: Duration
    private let now: () -> Date
    private var pendingWrite: Task<Void, Never>?
    #if canImport(UIKit)
    private var backgroundObserver: NSObjectProtocol?
    #endif

    public init(url: URL?, writeDelay: Duration = .milliseconds(400), now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.writeDelay = writeDelay
        self.now = now
        let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) }
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        drafts = (saved ?? [:]).filter { $0.value.savedAt > cutoff }
        #if canImport(UIKit)
        if url != nil {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
        #endif
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Composer", directoryHint: .isDirectory).appending(path: "drafts.json")
    }

    /// One tab's key: its Mac and its stable tab id (two Macs may both have an `s3`).
    public nonisolated static func key(macID: String, tabID: String) -> String { "\(macID)|\(tabID)" }

    public func text(for key: String) -> String? { drafts[key]?.text }

    /// Keeps `text` as the tab's draft; empty removes it.
    public func save(_ text: String, for key: String) {
        guard drafts[key]?.text != text else { return }
        if text.isEmpty {
            guard drafts.removeValue(forKey: key) != nil else { return }
            // Sent: off the disk now, not after the wait (still on `writer`, off the main thread).
            pendingWrite?.cancel()
            pendingWrite = nil
            write()
            return
        } else {
            drafts[key] = Entry(text: text, savedAt: now())
            if drafts.count > Self.limit {
                let oldest = drafts.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(drafts.count - Self.limit)
                for (old, _) in oldest { drafts[old] = nil }
            }
        }
        scheduleWrite()
    }

    /// A closed tab's draft goes with it.
    public func clear(_ key: String) { save("", for: key) }

    /// Writes now what waits to be written, and returns once it is on disk.
    public func flush() {
        if pendingWrite != nil {
            pendingWrite?.cancel()
            pendingWrite = nil
            write()
        }
        // The app is leaving the foreground (or a test reads the file back): wait for the writer.
        Self.writer.sync {}
    }

    /// Returns once every write handed to the writer is on disk (tests).
    static func waitForWriter() { writer.sync {} }

    /// One serial queue for every store's file: writes land in the order they were made.
    private static let writer = DispatchQueue(label: "dev.cmux.mobile.composer-drafts", qos: .utility)

    private func scheduleWrite() {
        guard url != nil, pendingWrite == nil else { return }
        let delay = writeDelay
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingWrite = nil
            self.write()
        }
    }

    #if DEBUG
    /// DEBUG: told of each draft file written on the main thread
    /// (`InputLatencyTrace.note`, `ComposerLinkUITests`).
    public static var mainThreadWrite: (@MainActor () -> Void)?
    #endif

    /// Hands a snapshot of the drafts to `writer`: the main thread copies a dictionary, no more.
    private func write() {
        guard let url else { return }
        let drafts = drafts
        Self.writer.async { Self.persist(drafts, to: url) }
    }

    private nonisolated static func persist(_ drafts: [String: Entry], to url: URL) {
        #if DEBUG
        if Thread.isMainThread { MainActor.assumeIsolated { mainThreadWrite?() } }
        #endif
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
