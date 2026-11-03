// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation
public import Observation
import CmuxNextCompat
import Darwin

/// One saved approval: an app this cmux client lets agents use without asking.
public nonisolated struct ComputerUseSavedApproval: Sendable, Hashable, Codable {
    public var app: ComputerUseApprovalApp
    /// When it was saved (Unix milliseconds).
    public var addedMs: Int64
    /// The collector that saved it: the Mac card or a Face ID signed phone answer.
    public var via: ComputerUseApprovalVia

    public init(app: ComputerUseApprovalApp, addedMs: Int64, via: ComputerUseApprovalVia) {
        self.app = app
        self.addedMs = addedMs
        self.via = via
    }

    enum CodingKeys: String, CodingKey {
        case app
        case addedMs = "added_ms"
        case via
    }
}

/// The saved approvals file of one cmux client (docs/computer-use-approvals.md, "always"):
/// `<Application Support>/<bundle id>/computer-use/approvals.json`, 0600 in a 0700 folder, so
/// stable, NIGHTLY, RC and each DEV tag keep separate lists. Not cmux.json and not
/// UserDefaults: an agent that can write settings cannot add to it, and only this app reads it.
/// All I/O runs off the main actor.
public nonisolated struct ComputerUseApprovalFile: Sendable {
    public let url: URL
    public let client: String

    public init(url: URL, client: String) {
        self.url = url
        self.client = client
    }

    /// This build's file.
    public static func standard(client: String, support: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        -> ComputerUseApprovalFile {
        let base = support ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return ComputerUseApprovalFile(url: base.appending(path: "\(client)/computer-use/approvals.json"), client: client)
    }

    struct Document: Codable {
        var v = 1
        var client: String
        var apps: [ComputerUseSavedApproval]
    }

    /// The saved list; empty when there is no file. A file of another client, or one that is
    /// not this user's 0600 regular file, reads as empty (fail closed: nothing is allowed).
    public func read() -> [ComputerUseSavedApproval] {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size < 1 << 20,
              let data = try? handle.blockingReadToEnd(),
              let document = try? JSONDecoder().decode(Document.self, from: data), document.v == 1,
              document.client == client else { return [] }
        return document.apps.filter { $0.app.identity != nil }
    }

    /// Writes the list atomically (a 0600 temporary file renamed over the old one).
    @discardableResult
    public func write(_ apps: [ComputerUseSavedApproval]) -> Bool {
        let folder = url.deletingLastPathComponent().path
        guard ComputerUseHelperDaemon.makePrivateDirectory(folder) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Document(client: client, apps: apps)) else { return false }
        let temporary = folder + "/.approvals.\(UUID().uuidString).tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let written = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return raw.isEmpty }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base + offset, raw.count - offset)
                if count <= 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
        let synced = written && fsync(descriptor) == 0
        close(descriptor)
        guard synced, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }
}

/// This cmux client's saved approvals in memory, mirrored to its ``ComputerUseApprovalFile``.
/// Changes apply at once (the worker hears them through ``onChange``); the file write runs off
/// the main actor, in order, and always writes the newest list. Changes made before the first
/// read finished are applied on top of what it read (a revoke is never lost).
@MainActor @Observable
public final class ComputerUseApprovalStore {
    public private(set) var apps: [ComputerUseSavedApproval] = []
    /// The first read finished (before it, the list holds only changes made since start).
    public private(set) var loaded = false
    @ObservationIgnored public let file: ComputerUseApprovalFile
    /// Runs after every change with the new list (the broker sends `approved_apps`).
    @ObservationIgnored public var onChange: @MainActor ([ComputerUseSavedApproval]) -> Void = { _ in }
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Revocations made before the first read finished: applied to what it reads.
    @ObservationIgnored private var revokedBeforeLoad: [ComputerUseApprovalApp] = []
    @ObservationIgnored private var revokedAllBeforeLoad = false

    public var client: String { file.client }

    public init(file: ComputerUseApprovalFile) {
        self.file = file
    }

    /// Reads the file once, off the main actor.
    public func load() async {
        if let loading { return await loading.value }
        let file = file
        let task = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { file.read() }.value
            self?.finishLoad(saved)
        }
        loading = task
        await task.value
    }

    private func finishLoad(_ saved: [ComputerUseSavedApproval]) {
        var merged = revokedAllBeforeLoad ? [] : saved.filter { entry in !revokedBeforeLoad.contains { $0.sameApp(as: entry.app) } }
        for entry in apps where !merged.contains(where: { $0.app.sameApp(as: entry.app) }) { merged.append(entry) }
        let changedFile = merged != saved
        revokedBeforeLoad = []
        revokedAllBeforeLoad = false
        loaded = true
        guard merged != apps || changedFile else { return }
        apps = merged
        changed()
    }

    /// Saves `app` (only a person's Always on the card or a Face ID signed phone Always).
    public func add(_ app: ComputerUseApprovalApp, via: ComputerUseApprovalVia, nowMs: Int64) {
        guard app.identity != nil, !contains(app) else { return }
        apps.append(ComputerUseSavedApproval(app: app, addedMs: nowMs, via: via))
        changed()
    }

    /// Removes `app` (nil: every app). Returns how many were removed.
    @discardableResult
    public func revoke(_ app: ComputerUseApprovalApp?) -> Int {
        let before = apps.count
        if let app {
            apps.removeAll { $0.app.sameApp(as: app) }
            if !loaded { revokedBeforeLoad.append(app) }
        } else {
            apps.removeAll()
            if !loaded { revokedAllBeforeLoad = true }
        }
        let removed = before - apps.count
        if removed > 0 { changed() }
        return removed
    }

    public func contains(_ app: ComputerUseApprovalApp) -> Bool { apps.contains { $0.app.sameApp(as: app) } }

    private func changed() {
        onChange(apps)
        guard loaded else { return } // finishLoad writes the merged list
        let file = file
        let previous = lastWrite
        // task-owner: one write per change, chained; each writes the newest list.
        lastWrite = Task { [weak self] in
            await previous?.value
            guard let snapshot = self?.apps else { return }
            await Task.detached(priority: .utility) { _ = file.write(snapshot) }.value
        }
    }

    /// Waits for every write so far (tests, quit).
    public func flush() async { await lastWrite?.value }
}
