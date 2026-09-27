import AppKit
import UniformTypeIdentifiers

/// Decides whether Cmd+V should send Ctrl+V to the agent running in a pane
/// instead of saving the clipboard image to a temporary file and pasting its
/// path (`terminal.agentImagePasteSendsCtrlV`, off by default).
///
/// Claude Code and Codex read an image straight from the macOS clipboard when
/// they receive Ctrl+V, and attach it the way they would in any terminal. The
/// rule only takes over when every condition holds, and each one falls back
/// to the existing temp-path paste:
///
/// - the setting is on;
/// - an agent that reads clipboard images on Ctrl+V (Claude Code or Codex) is
///   running in the pane right now, as reported by its agent hooks. Launch
///   commands and restored snapshots alone don't count, because Ctrl+V sent
///   to a shell after the agent exits would lose the image;
/// - the clipboard holds image data and nothing the paste path would insert
///   instead: no text, rich text, URL or file reference;
/// - the pane is local. For `cmux ssh`, detected SSH and Cloud panes the agent
///   reads a different machine's clipboard, so the upload path stays.
///
/// Arguments are closures so the cheaper checks short-circuit the pasteboard
/// read and the image-transfer target lookup.
enum TerminalAgentImagePasteRouting {
    /// The key sent instead of the paste.
    static let agentPasteKeyName = "ctrl+v"

    static func shouldSendAgentPasteKey(
        isEnabled: Bool,
        agentContext: () -> String,
        pasteboardTypes: () -> [NSPasteboard.PasteboardType],
        resolveTarget: () -> TerminalImageTransferTarget
    ) -> Bool {
        guard isEnabled,
              agentReadsClipboardImageOnCtrlV(agentContext: agentContext()),
              clipboardHoldsOnlyImageData(pasteboardTypes()) else {
            return false
        }
        return resolveTarget() == .local
    }

    /// Whether a live Claude Code or Codex process is attached to the pane,
    /// from the context built by `WorkspaceContentView.terminalAgentContext`.
    static func agentReadsClipboardImageOnCtrlV(agentContext: String) -> Bool {
        TextBoxAgentDetection.claudeCode.matchesActive(context: agentContext)
            || TextBoxAgentDetection.codex.matchesActive(context: agentContext)
    }

    /// Whether the pasteboard advertises image data and no type that the
    /// regular paste would prefer over the image (text, rich text, URLs, file
    /// references, promised files). Reads only the type list, never the data,
    /// so a lazy clipboard provider is not asked to render anything.
    static func clipboardHoldsOnlyImageData(
        _ types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        var hasImage = false
        for type in types {
            if nonImageContentTypes.contains(type) { return false }
            if let utType = UTType(type.rawValue) {
                if utType.conforms(to: .text) || utType.conforms(to: .url) {
                    return false
                }
                if utType.conforms(to: .image) { hasImage = true }
            }
            if type == .tiff || type == .png { hasImage = true }
        }
        return hasImage
    }

    /// Types that carry text, rich text, URLs or files, including legacy
    /// pasteboard names that have no conforming UTType.
    private static let nonImageContentTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .html,
        .rtf,
        .rtfd,
        .URL,
        .fileURL,
        NSPasteboard.PasteboardType(rawValue: "com.apple.flat-rtfd"),
        NSPasteboard.PasteboardType(rawValue: "NSStringPboardType"),
        NSPasteboard.PasteboardType(rawValue: "Apple HTML pasteboard type"),
        NSPasteboard.PasteboardType(rawValue: "NeXT Rich Text Format v1.0 pasteboard type"),
        NSPasteboard.PasteboardType(rawValue: "NeXT RTFD pasteboard type"),
        NSPasteboard.PasteboardType(rawValue: "Apple URL pasteboard type"),
        PasteboardFileURLReader.legacyFilenamesPboardType,
        PasteboardFileURLReader.promisedFileURLPasteboardType,
    ]
}
