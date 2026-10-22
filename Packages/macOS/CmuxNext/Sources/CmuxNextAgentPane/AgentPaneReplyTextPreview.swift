import Foundation

/// The first lines of a text file a reply names, for its path chip's hover card (`link.preview`,
/// Leo 2026-10-21: "all these I hope can be previewed"). The read is bounded: a regular file only
/// (no folder, FIFO, device or link, checked on the open handle), at most ``maximumBytes`` read and
/// ``maximumLines`` lines of at most ``maximumLineLength`` characters sent, and bytes that are not
/// UTF-8 text (a NUL, or no valid decoding) are never sent. The caller checks the place first
/// (``AgentPaneModel/previewReplyPath(_:)``).
nonisolated struct AgentPaneReplyTextPreview: Equatable, Sendable {
    static let maximumLines = 40
    static let maximumBytes = 16 << 10
    static let maximumLineLength = 400

    var lines: [String]
    /// More of the file exists than the lines sent.
    var truncated: Bool

    /// The file at `path` (canonical, already checked against the deny list), read off the main
    /// actor through one handle, so the file cannot be swapped between the checks and the read.
    @concurrent static func read(_ path: String) async -> Result<Self, AgentPaneReplyError> {
        // O_NOFOLLOW refuses a link; O_NONBLOCK keeps a FIFO from blocking the open.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.pathInvalid) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(.pathInvalid) }
        let data: Data
        do {
            // concurrency-allow: read(_:) is @concurrent, so this read never runs on the main actor
            data = try handle.read(upToCount: maximumBytes) ?? Data()
        } catch {
            return .failure(.pathInvalid)
        }
        return text(data, fileSize: Int(info.st_size))
    }

    /// `data`, the first bytes of a file of `fileSize` bytes, as preview lines; refused when it is
    /// not text.
    static func text(_ data: Data, fileSize: Int) -> Result<Self, AgentPaneReplyError> {
        guard !data.contains(0) else { return .failure(.pathInvalid) }
        var cut = data.count < fileSize
        // A read that stopped inside a character: drop its last bytes (at most three).
        var decoded = String(data: data, encoding: .utf8)
        var drop = 1
        while decoded == nil, cut, drop <= 3, drop <= data.count {
            decoded = String(data: data.dropLast(drop), encoding: .utf8)
            drop += 1
        }
        guard let decoded else { return .failure(.pathInvalid) }
        var lines = decoded.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        // A file that ends with its newline has no line after it.
        if lines.last?.isEmpty == true, !cut { lines.removeLast() }
        if lines.count > maximumLines {
            lines = Array(lines.prefix(maximumLines))
            cut = true
        }
        return .success(Self(lines: lines.map { String($0.prefix(maximumLineLength)) }, truncated: cut))
    }
}

extension AgentPaneModel {
    /// `link.preview`: the first lines of the text file a path chip names. Inside the roots it is
    /// read; outside them too, read-only, as an inline image is, unless
    /// `agentPane.links.outsideRoots` is `text`; a deny-listed path never, checked again after
    /// symlinks. Every refusal of an outside path answers `pathOutsideRoots`, so the page learns
    /// nothing about a file it is not shown.
    func previewReplyPath(_ text: String) async -> [String: Any] {
        let paths = replyPaths()
        guard let resolved = paths.resolve(text) else { return Self.replyFailure(.pathInvalid) }
        switch resolved.place {
        case .denied: return Self.replyFailure(.pathDenied)
        case .missing: return Self.replyFailure(.pathInvalid)
        case .root: break
        case .outside:
            guard replyLinks.settings().outsideRoots != .text else { return Self.replyFailure(.pathOutsideRoots) }
        }
        let refusal: AgentPaneReplyError = resolved.place == .outside ? .pathOutsideRoots : .pathInvalid
        guard let canonical = AcpmuxPathPolicy.canonical(resolved.path) else { return Self.replyFailure(refusal) }
        // A link may point a harmless name at a secret.
        guard !paths.isDenied(canonical) else { return Self.replyFailure(.pathDenied) }
        switch await AgentPaneReplyTextPreview.read(canonical) {
        case .success(let preview):
            return AgentPaneReply.success(["lines": preview.lines, "truncated": preview.truncated])
        case .failure:
            return Self.replyFailure(refusal)
        }
    }
}
