#if os(iOS)
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A file-backed transfer for an item returned by the Photos picker.
///
/// PhotosUI owns the URL in `ReceivedTransferredFile`, so copy it into an
/// app-owned temporary file before the picker transfer goes out of scope. The
/// terminal composer can then choose whether to downsample an image or stage
/// another media type as a file without loading the original asset into memory.
struct ImportedPhotoLibraryFile: Transferable, Sendable {
    enum Kind: Equatable, Sendable {
        case image
        case file
    }

    let url: URL
    let originalFileName: String
    let kind: Kind

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .livePhoto) { received in
            try importFile(received, kind: .file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try importFile(received, kind: .image)
        }
        FileRepresentation(importedContentType: .video) { received in
            try importFile(received, kind: .file)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try importFile(received, kind: .file)
        }
        FileRepresentation(importedContentType: .item) { received in
            try importFile(received, kind: .file)
        }
    }

    private static func importFile(
        _ received: ReceivedTransferredFile,
        kind: Kind
    ) throws -> Self {
        let pathExtension = received.file.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-photo-import-\(UUID().uuidString)\(suffix)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: received.file, to: destination)
        return Self(
            url: destination,
            originalFileName: received.file.lastPathComponent,
            kind: kind
        )
    }
}

private enum PhotoLibraryTransferError: Error {
    case timedOut
}

/// Serializes picker completion, cancellation, and the timeout so a stalled
/// iCloud asset cannot leave the composer staging task suspended forever.
private final class PhotoLibraryTransferRace: @unchecked Sendable {
    // lint:allow lock - synchronous continuation settlement keeps transfer,
    // timeout, and cancellation callbacks from resuming the load twice.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ImportedPhotoLibraryFile?, Error>?
    private var transferTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    func start(
        item: PhotosPickerItem,
        timeout: Duration,
        continuation: CheckedContinuation<ImportedPhotoLibraryFile?, Error>
    ) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let transferTask = Task { [self] in
            do {
                try Task.checkCancellation()
                let imported = try await item.loadTransferable(
                    type: ImportedPhotoLibraryFile.self
                )
                finish(.success(imported))
            } catch {
                finish(.failure(error))
            }
        }
        let timeoutTask = Task { [self] in
            do {
                try await Task.sleep(for: timeout)
                finish(.failure(PhotoLibraryTransferError.timedOut))
            } catch {
                // The transfer won or the parent task was cancelled.
            }
        }

        lock.lock()
        if didFinish {
            lock.unlock()
            transferTask.cancel()
            timeoutTask.cancel()
        } else {
            self.transferTask = transferTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(
        _ result: Result<ImportedPhotoLibraryFile?, Error>
    ) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        let transferTask = self.transferTask
        self.transferTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        transferTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

extension ImportedPhotoLibraryFile {
    /// Loads a Photos library asset with a bounded wait. iCloud-backed assets
    /// otherwise have no useful failure path when their network transfer stalls.
    static func load(
        _ item: PhotosPickerItem,
        timeout: Duration = .seconds(60)
    ) async throws -> ImportedPhotoLibraryFile? {
        let race = PhotoLibraryTransferRace()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                race.start(item: item, timeout: timeout, continuation: continuation)
            }
        }, onCancel: {
            race.cancel()
        })
    }
}
#endif
