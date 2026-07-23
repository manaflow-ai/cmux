public import AppKit
public import CmuxTerminalCore
public import GhosttyKit
internal import os

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
/// service is nonisolated and `Sendable`: every method is a pure transform of
/// its pasteboard argument except two tiny lock-guarded values (the owned
/// temp-file set and the one-shot write capture), the sanctioned shape for
/// state shared with synchronous callbacks.
public final class TerminalPasteboardService: Sendable {
    /// One-shot interception slot for ``captureNextStandardClipboardWrite(matching:_:)``.
    final class ClipboardWriteCapture: Sendable {
        private let lock = NSLock()
        // SAFETY: guarded by `lock`; written by the runtime's write-clipboard
        // callback thread and read by the capturing caller.
        nonisolated(unsafe) private var capturedValue: String?

        /// Predicate deciding whether a standard-clipboard write belongs to
        /// this capture. Writes it rejects pass through to the real
        /// pasteboard and leave the capture armed, so an unrelated write
        /// (e.g. a user copy racing a VT export) is not swallowed.
        let accepts: @Sendable (String) -> Bool

        init(accepts: @escaping @Sendable (String) -> Bool) {
            self.accepts = accepts
        }

        /// Stores the diverted clipboard string.
        func capture(_ value: String) {
            lock.lock()
            capturedValue = value
            lock.unlock()
        }

        /// The diverted clipboard string, if a write was captured.
        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return capturedValue
        }
    }

    static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    static let temporaryImageFilenamePrefix = "clipboard-"
    static let objectReplacementCharacter = Character(UnicodeScalar(0xFFFC)!)
    /// Mirrors the clipboard-image size cap applied to every materialization
    /// path (local paste and remote-forwarded image bytes alike).
    static let maxClipboardImageSize = 10 * 1024 * 1024  // 10 MB

    // SAFETY: immutable reference; NSPasteboard handles are usable from any
    // thread and the legacy code already wrote to this pasteboard from
    // ghostty runtime threads.
    nonisolated(unsafe) private let selectionPasteboard: NSPasteboard

    // SAFETY: immutable reference; same argument as `selectionPasteboard`.
    // Injectable so tests can exercise standard-location writes without
    // touching the real general pasteboard.
    nonisolated(unsafe) private let standardPasteboard: NSPasteboard

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "terminal.pasteboard"
    )

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
    ///     Tests inject a scratch directory; the app uses the user's
    ///     temporary directory.
    ///   - standardPasteboard: The pasteboard backing the standard clipboard
    ///     location. Tests inject a scratch pasteboard; the app uses
    ///     `NSPasteboard.general`.
    public init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        standardPasteboard: NSPasteboard = .general
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.standardPasteboard = standardPasteboard
        self.selectionPasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
        )
    }
}

extension TerminalPasteboardService: TerminalClipboardWriting {
    /// Writes a string to the given ghostty clipboard location, honoring an
    /// armed one-shot capture for the standard location.
    ///
    /// An armed capture only consumes writes its predicate accepts; any other
    /// standard-location write (e.g. a user copy racing a VT export) passes
    /// through to the real pasteboard with the capture left armed.
    public func writeString(_ string: String, to location: ghostty_clipboard_e) {
        if location == GHOSTTY_CLIPBOARD_STANDARD {
            standardClipboardWriteCaptureLock.lock()
            let armed = standardClipboardWriteCapture
            standardClipboardWriteCaptureLock.unlock()

            if let armed {
                if armed.accepts(string) {
                    // Claim the one-shot slot atomically: only the write that
                    // actually clears it may capture. A concurrent matching
                    // write that loses this race falls through to the real
                    // pasteboard instead of overwriting the captured value
                    // and being swallowed.
                    standardClipboardWriteCaptureLock.lock()
                    let claimed = standardClipboardWriteCapture === armed
                    if claimed {
                        standardClipboardWriteCapture = nil
                    }
                    standardClipboardWriteCaptureLock.unlock()
                    if claimed {
                        armed.capture(string)
                        return
                    }
                } else {
                    Self.logger.info(
                        "standard write passed through armed capture (length \(string.count, privacy: .public))"
                    )
                }
            }
        }

        // An empty payload (e.g. copy-on-select firing after a TUI redraw
        // already invalidated the selection) must not clear the clipboard:
        // clearContents-then-write-nothing silently destroys whatever the
        // user last copied.
        guard !string.isEmpty else {
            Self.logger.info("ignored empty clipboard write")
            return
        }

        guard let pasteboard = pasteboard(for: location) else { return }
        let clearedChangeCount = pasteboard.clearContents()
        if !pasteboard.setString(string, forType: .string) {
            // A contended pasteboard can reject the write after clearContents,
            // leaving the clipboard empty. Retry once so the failure is not
            // silent data loss — but only while nothing else has written in
            // the meantime, so the retry never clobbers a newer value.
            var retried = false
            if pasteboard.changeCount == clearedChangeCount {
                pasteboard.clearContents()
                retried = pasteboard.setString(string, forType: .string)
            }
            Self.logger.error(
                "pasteboard setString failed (length \(string.count, privacy: .public)), retry \(retried ? "succeeded" : "skipped-or-failed", privacy: .public)"
            )
        }
    }

    /// Arms a one-shot diversion of the next matching standard-clipboard
    /// write that happens while `action` runs, returning the diverted string.
    ///
    /// - Parameters:
    ///   - predicate: Decides whether a given standard-clipboard write is the
    ///     one this capture is waiting for. Non-matching writes reach the
    ///     real pasteboard and leave the capture armed, so unrelated writers
    ///     (a user copy, another surface) are not swallowed. Pass a predicate
    ///     as narrow as the expected payload allows — e.g. "an existing file
    ///     under the temporary directory" for a VT screen export.
    ///   - action: The operation expected to trigger the write.
    ///
    /// Returns `nil` without running a capture when another capture is
    /// already in flight: replacing the armed slot would let one operation's
    /// write satisfy the other's capture (both predicates accept export
    /// paths), handing the wrong content to the wrong caller. Callers
    /// already treat `nil` as "fall back to a non-capture read".
    @discardableResult
    public func captureNextStandardClipboardWrite(
        matching predicate: @escaping @Sendable (String) -> Bool = { _ in true },
        _ action: () -> Bool
    ) -> String? {
        let capture = ClipboardWriteCapture(accepts: predicate)
        standardClipboardWriteCaptureLock.lock()
        let alreadyArmed = standardClipboardWriteCapture != nil
        if !alreadyArmed {
            standardClipboardWriteCapture = capture
        }
        standardClipboardWriteCaptureLock.unlock()
        guard !alreadyArmed else {
            Self.logger.info("clipboard capture rejected: another capture is in flight")
            return nil
        }

        defer {
            standardClipboardWriteCaptureLock.lock()
            if standardClipboardWriteCapture === capture {
                standardClipboardWriteCapture = nil
            }
            standardClipboardWriteCaptureLock.unlock()
        }

        guard action() else { return nil }
        return capture.value
    }
}

extension TerminalPasteboardService {
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
            try? FileManager.default.removeItem(at: normalizedURL)
        }
    }

    /// Deletes every temporary image file this service still owns.
    public func cleanupAllOwnedTemporaryImageFiles() {
        temporaryImageOwnershipLock.lock()
        let paths = ownedTemporaryImagePaths
        ownedTemporaryImagePaths.removeAll()
        temporaryImageOwnershipLock.unlock()

        for path in paths {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
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
