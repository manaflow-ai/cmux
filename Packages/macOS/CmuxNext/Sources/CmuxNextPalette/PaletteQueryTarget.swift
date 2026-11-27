public import Foundation

/// A place the palette's query names: an existing file or folder, or a web
/// address (`PaletteQueryTargetParser`). Cmd-P and Cmd-Shift-P offer to open
/// it, or to ask an agent about it.
public enum PaletteQueryTarget: Equatable, Sendable {
    /// An existing regular file, as an absolute file URL.
    case file(URL)
    /// An existing folder, as an absolute file URL.
    case folder(URL)
    /// A web address (`http`, `https`), with a scheme added when the query had none.
    case web(URL)

    /// What a row shows and an agent prompt quotes: a `~/` path or the URL.
    public var display: String {
        switch self {
        case .file(let url), .folder(let url): abbreviatePath(url.path)
        case .web(let url): url.absoluteString
        }
    }

    /// What an agent's prompt names: the absolute path or the URL.
    public var reference: String {
        switch self {
        case .file(let url), .folder(let url): url.path
        case .web(let url): url.absoluteString
        }
    }

    /// The text a new agent chat starts with: the place, then the user's
    /// words (`prompt`) when there are any, else room for them.
    public func agentText(prompt: String?) -> String {
        guard let prompt, !prompt.isEmpty else { return reference + "\n\n" }
        return reference + "\n\n" + prompt
    }

    /// The folder an agent asked about this place works in: the folder
    /// itself, a file's folder, nothing for a web address.
    public var workingDirectory: String? {
        switch self {
        case .folder(let url): url.path
        case .file(let url): url.deletingLastPathComponent().path
        case .web: nil
        }
    }
}

/// A parsed query: the place, and the words typed after it (the prompt for
/// Ask Agent; nil when there are none).
public struct PaletteQueryMatch: Equatable, Sendable {
    public var target: PaletteQueryTarget
    public var trailingText: String?

    public init(target: PaletteQueryTarget, trailingText: String? = nil) {
        self.target = target
        self.trailingText = trailingText
    }
}
