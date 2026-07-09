public import AppKit
public import CMUXAgentLaunch
public import Foundation
import UniformTypeIdentifiers

/// A textbox draft attachment lifted out of the app-target `TextBoxInput.swift`.
///
/// The value half of the textbox attachment: the display name, the text and
/// path it submits, the optional backing local file URL, an optional thumbnail,
/// and whether its temporary local URL should be cleaned up when disposed. It
/// conforms to `TextBoxSubmissionAttachment` (owned by `CMUXAgentLaunch`) so the
/// submission planner reads only `submissionText`/`submissionPath`/`localURL`/`isImage`.
///
/// The app-coupled members (shell-escaped path, local-file-submission check,
/// submission-text builders, and the draft-store cleanup/flush hooks) stay in an
/// app-target extension on this type, since they reach `TerminalImageTransferPlanner`
/// and `GhosttyApp` which live in the executable target.
public struct TextBoxAttachment: Identifiable, TextBoxSubmissionAttachment {
    public let id = UUID()
    public let displayName: String
    public let submissionText: String
    public let submissionPath: String
    public let localURL: URL?
    public let thumbnail: NSImage?
    public let cleanupLocalURLWhenDisposed: Bool

    public init(
        displayName: String,
        submissionText: String,
        submissionPath: String,
        localURL: URL?,
        cleanupLocalURLWhenDisposed: Bool = false
    ) {
        let standardizedURL = localURL?.standardizedFileURL
        let fallbackName = standardizedURL?.lastPathComponent ?? URL(fileURLWithPath: submissionPath).lastPathComponent
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallbackName.isEmpty ? submissionPath : fallbackName)
            : displayName
        self.submissionText = submissionText
        self.submissionPath = submissionPath
        self.localURL = standardizedURL
        self.thumbnail = standardizedURL.flatMap { TextBoxAttachment.makeThumbnail(for: $0) }
        self.cleanupLocalURLWhenDisposed = cleanupLocalURLWhenDisposed
    }

    public init(
        localURL: URL,
        submissionText: String,
        submissionPath: String? = nil,
        cleanupLocalURLWhenDisposed: Bool = false
    ) {
        let standardizedURL = localURL.standardizedFileURL
        self.displayName = standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path
            : standardizedURL.lastPathComponent
        self.submissionText = submissionText
        self.submissionPath = submissionPath ?? standardizedURL.path
        self.localURL = standardizedURL
        self.thumbnail = TextBoxAttachment.makeThumbnail(for: standardizedURL)
        self.cleanupLocalURLWhenDisposed = cleanupLocalURLWhenDisposed
    }

    public var isImage: Bool {
        if thumbnail != nil { return true }
        guard let localURL else { return false }
        return TextBoxAttachment.isImageFileURL(localURL)
    }

    private static func makeThumbnail(for url: URL) -> NSImage? {
        guard TextBoxAttachment.isImageFileURL(url),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}
