public import AppKit
public import CmuxTerminalCore
public import GhosttyKit

/// The terminal's pasteboard capability: clipboard reads and writes for the
/// ghostty runtime, plus materialization of pasteboard images into owned
/// temporary files for paste and drag flows.
///
/// Replaces the legacy `GhosttyPasteboardHelper` namespace enum. Exactly one
/// instance must serve the whole process: temporary-file ownership and the
/// one-shot write capture are process-wide hand-offs between independent call
/// sites (a file materialized by the paste path is cleaned up by an upload
/// completion), so splitting them across instances would silently leak files.
/// The composition point constructs the single instance and injects it.
///
/// Isolation design: callers are synchronous and arrive on several threads at
/// once. The ghostty write-clipboard callback fires on runtime threads and
/// cannot await, view paste paths run on the main actor, and upload
/// completions land on background queues. An actor would force `async` onto
/// the C callback path and `@MainActor` would require `assumeIsolated`, so the
/// service is nonisolated and `Sendable`: mutable ownership, capture, and
/// transaction-lane state are lock guarded, the sanctioned shape for state
/// shared with synchronous callbacks.
public final class TerminalPasteboardService: Sendable {
    /// Resolves rollback contents outside the lane's synchronous caller.
    public typealias PreviousContentsCapture = @Sendable (
        TerminalPasteboardContentsCaptureRequest
    ) async -> TerminalPasteboardContentsSnapshot?

    /// One-shot interception slot for ``captureNextStandardClipboardWrite(_:)``.
    final class ClipboardWriteCapture: Sendable {
        private let lock = NSLock()
        // SAFETY: guarded by `lock`; written by the runtime's write-clipboard
        // callback thread and read by the capturing caller.
        nonisolated(unsafe) private var capturedRepresentations:
            [TerminalClipboardRepresentation]?

        /// Stores the diverted clipboard representations.
        func capture(_ representations: [TerminalClipboardRepresentation]) {
            lock.lock()
            capturedRepresentations = representations
            lock.unlock()
        }

        /// Every diverted representation, preserving Ghostty's formatting.
        var representations: [TerminalClipboardRepresentation]? {
            lock.lock()
            defer { lock.unlock() }
            return capturedRepresentations
        }
    }

    static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    static let temporaryImageFilenamePrefix = "clipboard-"
    static let objectReplacementCharacter = Character(UnicodeScalar(0xFFFC)!)
    /// Maximum raw image payload accepted by remote/mobile materialization.
    public static let maximumImageDataByteCount = 10 * 1024 * 1024
    /// Mirrors the clipboard-image size cap applied to every materialization
    /// path (local paste and remote-forwarded image bytes alike).
    static let maxClipboardImageSize = maximumImageDataByteCount

    // SAFETY: immutable references; NSPasteboard handles are usable from any
    // thread and the legacy code already wrote to these pasteboards from
    // ghostty runtime threads.
    nonisolated(unsafe) private let standardPasteboard: NSPasteboard
    nonisolated(unsafe) private let selectionPasteboard: NSPasteboard
    private let standardPasteboardLane: TerminalPasteboardTransactionLane
    private let selectionPasteboardLane: TerminalPasteboardTransactionLane

    // SAFETY: FileManager supports concurrent use; this injected reference is immutable.
    nonisolated(unsafe) let fileManager: FileManager

    /// The directory that owned temporary image files are written into.
    let temporaryDirectory: URL

    private let temporaryImageOwnershipLock = NSLock()
    // SAFETY: guarded by `temporaryImageOwnershipLock`; mutated from
    // synchronous callers on arbitrary threads (paste paths, upload
    // completions, app termination cleanup).
    nonisolated(unsafe) private var ownedTemporaryImagePaths: Set<String> = []

    private let standardClipboardWriteCaptureLock = NSLock()
    // SAFETY: guarded by `standardClipboardWriteCaptureLock`; armed on the
    // capturing caller's thread and consumed by the runtime's
    // write-clipboard callback thread.
    nonisolated(unsafe) private var standardClipboardWriteCapture: ClipboardWriteCapture?

    /// Creates the process's pasteboard service.
    ///
    /// - Parameters:
    ///   - temporaryDirectory: Destination for owned temporary image files.
    ///     Tests inject a scratch directory; `nil` uses `fileManager`'s
    ///     temporary directory.
    ///   - fileManager: Filesystem dependency used for moves, attributes, and
    ///     cleanup.
    public convenience init(
        temporaryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.init(
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager,
            previousContentsCapture: { _ in nil }
        )
    }

    /// Creates the process pasteboard service with an isolated rollback
    /// snapshot provider.
    ///
    /// The app injects its killable worker-backed provider. Package clients
    /// that never reserve temporary mutations can use the simpler initializer.
    public convenience init(
        temporaryDirectory: URL? = nil,
        fileManager: FileManager = .default,
        previousContentsCapture: @escaping PreviousContentsCapture
    ) {
        self.init(
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager,
            standardPasteboard: .general,
            selectionPasteboard: NSPasteboard(
                name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
            ),
            previousContentsCapture: previousContentsCapture
        )
    }

    init(
        temporaryDirectory: URL? = nil,
        fileManager: FileManager = .default,
        standardPasteboard: NSPasteboard,
        selectionPasteboard: NSPasteboard,
        maximumQueuedClipboardOperations: Int = TerminalPasteboardTransactionLane
            .defaultMaximumQueuedOperations,
        maximumQueuedClipboardWriteBytes: Int = TerminalPasteboardTransactionLane
            .defaultMaximumQueuedWriteBytes,
        previousContentsCapture: @escaping PreviousContentsCapture = { _ in nil }
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory =
            temporaryDirectory ?? fileManager.temporaryDirectory
        self.standardPasteboard = standardPasteboard
        self.selectionPasteboard = selectionPasteboard
        self.standardPasteboardLane = TerminalPasteboardTransactionLane(
            pasteboard: standardPasteboard,
            maximumQueuedOperations: maximumQueuedClipboardOperations,
            maximumQueuedWriteBytes: maximumQueuedClipboardWriteBytes,
            previousContentsCapture: previousContentsCapture
        )
        self.selectionPasteboardLane = TerminalPasteboardTransactionLane(
            pasteboard: selectionPasteboard,
            maximumQueuedOperations: maximumQueuedClipboardOperations,
            maximumQueuedWriteBytes: maximumQueuedClipboardWriteBytes,
            previousContentsCapture: previousContentsCapture
        )
    }
}

extension TerminalPasteboardService: TerminalClipboardWriting {
    /// Publishes all textual representations as one pasteboard item, honoring
    /// an armed one-shot capture for the standard location.
    public func writeRepresentations(
        _ representations: [TerminalClipboardRepresentation],
        to location: ghostty_clipboard_e
    ) {
        guard !representations.isEmpty else { return }

        if location == GHOSTTY_CLIPBOARD_STANDARD {
            var capture: ClipboardWriteCapture?
            standardClipboardWriteCaptureLock.lock()
            capture = standardClipboardWriteCapture
            if capture != nil {
                standardClipboardWriteCapture = nil
            }
            standardClipboardWriteCaptureLock.unlock()

            if let capture {
                capture.capture(representations)
                return
            }
        }

        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            _ = enqueueRepresentations(
                representations,
                in: standardPasteboardLane
            )
        case GHOSTTY_CLIPBOARD_SELECTION:
            _ = enqueueRepresentations(
                representations,
                in: selectionPasteboardLane
            )
        default:
            return
        }
    }

    /// Writes a string to the given ghostty clipboard location, honoring an
    /// armed one-shot capture for the standard location.
    public func writeString(_ string: String, to location: ghostty_clipboard_e) {
        writeRepresentations(
            [.init(mimeType: "text/plain", string: string)],
            to: location
        )
    }

    /// Arms a one-shot diversion of the next standard-clipboard write that
    /// happens while `action` runs, returning the diverted string.
    @discardableResult
    public func captureNextStandardClipboardWrite(_ action: () -> Bool) -> String? {
        guard let representations = captureNextStandardClipboardRepresentations(
            action
        ) else {
            return nil
        }
        return representations.first(where: {
            normalizedTerminalClipboardMIMEType($0.mimeType) == "text/plain"
        })?.string
            ?? representations.first?.string
    }

    /// Diverts one synchronous standard-clipboard write with every formatting
    /// representation intact.
    public func captureNextStandardClipboardRepresentations(
        _ action: () -> Bool
    ) -> [TerminalClipboardRepresentation]? {
        let capture = ClipboardWriteCapture()
        standardClipboardWriteCaptureLock.lock()
        standardClipboardWriteCapture = capture
        standardClipboardWriteCaptureLock.unlock()

        defer {
            standardClipboardWriteCaptureLock.lock()
            if standardClipboardWriteCapture === capture {
                standardClipboardWriteCapture = nil
            }
            standardClipboardWriteCaptureLock.unlock()
        }

        guard action() else { return nil }
        return capture.representations
    }

    private func enqueueRepresentations(
        _ representations: [TerminalClipboardRepresentation],
        in lane: TerminalPasteboardTransactionLane
    ) -> Bool {
        let item = NSPasteboardItem()
        var writtenTypes = Set<NSPasteboard.PasteboardType>()
        for representation in representations {
            let type = terminalPasteboardType(
                forMIMEType: representation.mimeType
            )
            guard writtenTypes.insert(type).inserted else { continue }
            _ = item.setString(representation.string, forType: type)
        }
        let contents = TerminalPasteboardItemSnapshot.snapshots(from: [item])
        guard !contents.isEmpty else { return false }
        return lane.enqueueMutation(.init(
            contents: contents,
            condition: nil,
            capturesPreviousContents: false
        ))
    }

}

func normalizedTerminalClipboardMIMEType(_ mimeType: String) -> String {
    let base = mimeType.split(separator: ";", maxSplits: 1).first ?? Substring(mimeType)
    return String(base)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

func terminalPasteboardType(
    forMIMEType mimeType: String
) -> NSPasteboard.PasteboardType {
    switch normalizedTerminalClipboardMIMEType(mimeType) {
    case "text/plain":
        return .string
    case "text/html":
        return .html
    case "text/rtf":
        return .rtf
    default:
        return NSPasteboard.PasteboardType(mimeType)
    }
}

extension TerminalPasteboardService {
    func managedPasteboardLane(
        for pasteboard: NSPasteboard
    ) -> TerminalPasteboardTransactionLane? {
        if pasteboard.name == standardPasteboard.name {
            return standardPasteboardLane
        }
        if pasteboard.name == selectionPasteboard.name {
            return selectionPasteboardLane
        }
        return nil
    }

    /// Reserves this clipboard location in process-wide read/write order.
    ///
    /// Callers must finish the returned lease as soon as pasteboard-backed
    /// preparation ends. A full bounded lane rejects new native reads.
    public func reserveClipboardRead(
        from location: ghostty_clipboard_e
    ) -> TerminalPasteboardReadLease? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return standardPasteboardLane.reserveRead()
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboardLane.reserveRead()
        default:
            return nil
        }
    }

    /// The pasteboard backing a ghostty clipboard location.
    public func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return standardPasteboard
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    /// Whether the file was materialized by this service and is still owned.
    public func isOwnedTemporaryImageFile(_ fileURL: URL) -> Bool {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        let isOwned = ownedTemporaryImagePaths.contains(normalizedPath)
        temporaryImageOwnershipLock.unlock()
        return isOwned
    }

    /// Deletes the given files if (and only if) this service still owns them,
    /// consuming ownership.
    public func cleanupTransferredTemporaryImageFiles(_ fileURLs: [URL]) {
        for fileURL in fileURLs {
            let normalizedURL = fileURL.standardizedFileURL
            guard normalizedURL.isFileURL,
                  consumeOwnedTemporaryImageFile(normalizedURL) else {
                continue
            }
            try? fileManager.removeItem(at: normalizedURL)
        }
    }

    /// Deletes every temporary image file this service still owns.
    public func cleanupAllOwnedTemporaryImageFiles() {
        temporaryImageOwnershipLock.lock()
        let paths = ownedTemporaryImagePaths
        ownedTemporaryImagePaths.removeAll()
        temporaryImageOwnershipLock.unlock()

        for path in paths {
            try? fileManager.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    func registerOwnedTemporaryImageFile(_ fileURL: URL) {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        ownedTemporaryImagePaths.insert(normalizedPath)
        temporaryImageOwnershipLock.unlock()
    }

    private func consumeOwnedTemporaryImageFile(_ fileURL: URL) -> Bool {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        let didOwnFile = ownedTemporaryImagePaths.remove(normalizedPath) != nil
        temporaryImageOwnershipLock.unlock()
        return didOwnFile
    }

#if DEBUG
    /// Test bridge: registers an arbitrary file as owned so cleanup paths can
    /// be exercised deterministically.
    public func debugRegisterOwnedTemporaryImageFile(_ fileURL: URL) {
        registerOwnedTemporaryImageFile(fileURL)
    }
#endif
}
