#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Observation

/// Where an attachment goes: a Mac, and the tab's folder there (nil: the Mac's uploads folder).
public struct AttachmentDestination: Sendable, Equatable {
    public let macID: String
    public let cwd: String?

    public init(macID: String, cwd: String?) {
        self.macID = macID
        self.cwd = LinkUpload.folder(cwd)
    }
}

/// The app's one attachment upload queue: glue over the Rust engine
/// (`AttachmentUploads`, cmux-mobile-link-ffi `attachment_upload.rs`), which
/// decides everything (bounds, retries from the last byte the Mac acked,
/// waiting for a link, the uploads-folder fallback). Swift only hands it
/// files and links and mirrors its progress for SwiftUI
/// (design/attachment-upload.md).
///
/// An upload starts when the attachment is picked, not on Send, so the bytes
/// move while the person types; `cancel` returns at once from any stage.
@MainActor @Observable
public final class AttachmentUploadClient {
    public static let shared = AttachmentUploadClient()

    /// The newest progress of each upload, by id.
    public private(set) var progress: [String: UploadProgress] = [:]

    @ObservationIgnored private var engine: AttachmentUploads!
    @ObservationIgnored private var destinations: [String: AttachmentDestination] = [:]
    /// Security scopes held open while the engine reads a Files pick; closed when the upload ends.
    @ObservationIgnored private var scopes: [String: ScopedFile.Access] = [:]
    /// Files this client wrote (pasted bytes, compressed videos): removed when their upload ends.
    @ObservationIgnored private var ownedFiles: [String: URL] = [:]

    init() {
        engine = AttachmentUploads(observer: Bridge(client: self))
    }

    /// The Mac's served link changed (nil: none). Uploads waiting for it go on, from their last acked byte.
    public func setLink(macID: String, link: (any MacLink)?) {
        engine.setLink(macId: macID, link: link?.ffiLinkHandle as? LinkHandle)
    }

    /// Starts sending the file at `url` (kept by URL, never read whole; a Files
    /// pick's scope stays open until the upload ends). Returns its id.
    public func start(_ url: URL, name: String, to destination: AttachmentDestination, ownsFile: Bool = false) -> String {
        let id = reserve(name: name, to: destination)
        fileReady(id, url: url, ownsFile: ownsFile)
        return id
    }

    /// Starts sending bytes held in memory (a pasted or camera image): written
    /// to the outbox folder first, so the engine streams a file either way.
    public func start(_ data: Data, name: String, to destination: AttachmentDestination) -> String {
        let id = reserve(name: name, to: destination)
        fileReady(id, data: data, name: name)
        return id
    }

    /// A reserved upload's bytes, held in memory: written to the outbox folder, then sent as
    /// `name` on the Mac.
    public func fileReady(_ id: String, data: Data, name: String) {
        guard acceptsFile(id) else { return }
        do {
            let url = try Self.outboxFile(id: id, name: name)
            try data.write(to: url, options: .atomic)
            fileReady(id, url: url, name: name, ownsFile: true)
        } catch {
            engine.cancel(uploadId: id)
        }
    }

    /// An upload whose file is still being made (a video being compressed):
    /// shown as `compressing` until ``fileReady(_:url:ownsFile:)``.
    public func reserve(name: String, to destination: AttachmentDestination) -> String {
        let id = engine.reserve(spec: UploadSpec(uploadId: nil, macId: destination.macID, name: name, cwd: destination.cwd))
        destinations[id] = destination
        if let now = engine.progress(uploadId: id) { progress[id] = now }
        return id
    }

    public func compressProgress(_ id: String, fraction: Double) {
        engine.compressProgress(uploadId: id, fraction: fraction)
    }

    /// The reserved upload's file is ready; `name` (when given) replaces the reserved name on
    /// the Mac (a re-encode made another kind of file).
    public func fileReady(_ id: String, url: URL, name: String? = nil, ownsFile: Bool = false) {
        // An export can finish after Stop/forget, before its queued progress callback arrives.
        // Consult Rust's state before taking a new security scope or retaining the export.
        guard acceptsFile(id) else {
            if ownsFile { Self.removeOwnedFile(url) }
            return
        }
        if ownsFile {
            ownedFiles[id] = url
        } else {
            scopes[id] = ScopedFile(url).open()
        }
        if let name {
            engine.fileReadyAs(uploadId: id, path: url.path, name: name)
        } else {
            engine.fileReady(uploadId: id, path: url.path)
        }
    }

    private func acceptsFile(_ id: String) -> Bool {
        destinations[id] != nil && engine.progress(uploadId: id)?.isFinished == false
    }

    /// Stops the upload at any stage, at once: nothing waits on the network.
    public func cancel(_ id: String) {
        engine.cancel(uploadId: id)
        release(id)
    }

    /// Releases a completed upload. Late observer tasks cannot recreate a forgotten entry.
    public func forget(_ id: String) {
        guard engine.progress(uploadId: id)?.isFinished == true else { return }
        destinations[id] = nil
        progress[id] = nil
        release(id)
        engine.forget(uploadId: id)
    }

    /// The file's absolute path on the Mac once it is there whole; throws the
    /// engine's failure (with its sentence) or `cancelled`.
    public func wait(_ id: String) async throws -> String {
        do {
            return try await engine.wait(uploadId: id)
        } catch let error as CmuxMobileError {
            throw Self.failure(error)
        }
    }

    /// One upload over one given link, start to end, for callers that hold a
    /// link rather than a Mac (chat attachments, the upload probe,
    /// ``LinkUpload/upload(_:name:cwd:over:scope:)``): the engine's bounds and
    /// retries from the last acked byte on that link; cancelling the calling
    /// task cancels the upload at once.
    public func upload(_ payload: LinkUpload.Payload, name: String, cwd: String?, over link: LinkHandle) async throws -> String {
        let key = "link-\(UUID().uuidString)"
        engine.setLink(macId: key, link: link)
        defer { engine.setLink(macId: key, link: nil) }
        let destination = AttachmentDestination(macID: key, cwd: cwd)
        let id = switch payload {
        case .data(let data): start(data, name: name, to: destination)
        case .file(let url): start(url, name: name, to: destination)
        }
        defer { forget(id) }
        return try await withTaskCancellationHandler {
            try await wait(id)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    static func failure(_ error: CmuxMobileError) -> LinkUpload.Failure {
        switch error {
        case .Refused(let code, let message): LinkUpload.Failure(code: code, message: message)
        case .Timeout: LinkUpload.Failure(code: "timeout", message: "The upload timed out.")
        default: LinkUpload.Failure(code: "failed", message: String(describing: error))
        }
    }

    func apply(_ update: UploadProgress) {
        guard let destination = destinations[update.uploadId],
              progress[update.uploadId]?.isFinished != true else { return }
        if update.confirmedBytes > (progress[update.uploadId]?.confirmedBytes ?? 0) {
            UploadActivity.advanced(macID: destination.macID)
        }
        // Main-actor tasks from different observer threads can arrive out of order. Keep the
        // confirmed high-water mark so an old callback cannot make a replay look like new bytes.
        var newest = update
        newest.confirmedBytes = max(update.confirmedBytes, progress[update.uploadId]?.confirmedBytes ?? 0)
        progress[update.uploadId] = newest
        switch update.stage {
        case .done, .failed, .cancelled: release(update.uploadId)
        case .compressing, .waitingForMac, .uploading, .finishing: break
        }
    }

    private func release(_ id: String) {
        scopes.removeValue(forKey: id)?.close()
        if let file = ownedFiles.removeValue(forKey: id) {
            Self.removeOwnedFile(file)
        }
    }

    private static func removeOwnedFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        // Only the file was handed to us. rmdir removes an empty export folder without ever
        // recursively deleting another file that happens to be in the same parent.
        #if canImport(Darwin)
        _ = file.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.rmdir(path)
        }
        #endif
    }

    /// `Caches/attachment-outbox/<id>/<name>`: one folder per upload, so names never collide.
    static func outboxFile(id: String, name: String) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = caches.appendingPathComponent("attachment-outbox", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
    }

    /// The engine calls back on its own threads; SwiftUI reads on the main actor.
    private final class Bridge: UploadObserver, @unchecked Sendable {
        weak var client: AttachmentUploadClient?

        init(client: AttachmentUploadClient) { self.client = client }

        func onProgress(progress: UploadProgress) {
            Task { @MainActor [weak client] in client?.apply(progress) }
        }
    }
}

extension UploadProgress {
    /// 0...1 of the bytes the Mac has (sent bytes before a Mac that sends no acks).
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(max(ackedBytes, 0)) / Double(totalBytes))
    }

    public var isFinished: Bool {
        switch stage {
        case .done, .failed, .cancelled: true
        case .compressing, .waitingForMac, .uploading, .finishing: false
        }
    }
}
#endif
