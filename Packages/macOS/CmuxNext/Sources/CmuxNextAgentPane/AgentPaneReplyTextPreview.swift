import Darwin
import Foundation

/// The first lines of a text file a reply names, for its path chip's hover card (`link.preview`,
/// Leo 2026-10-21: "all these I hope can be previewed"). The read is bounded: a regular file only
/// (no folder, FIFO, device or link: checked before the open, so a device is never opened, and
/// again on the open handle), at most ``maximumBytes`` read and
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
    /// actor. `accept` checks the open handle's own path again (the deny list, the roots), so a
    /// folder above the file swapped after the place check cannot redirect the read.
    @concurrent static func read(_ path: String, accept: @Sendable (String) -> Bool) async -> Result<Self, AgentPaneReplyError> {
        var before = stat()
        guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return .failure(.pathInvalid) }
        // O_NOFOLLOW refuses a link; O_NONBLOCK keeps a FIFO swapped in from blocking the open.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.pathInvalid) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == before.st_dev, info.st_ino == before.st_ino else { return .failure(.pathInvalid) }
        var real = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &real) != -1, accept(String(decoding: real.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        else { return .failure(.pathInvalid) }
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
        // "\r\n" is one Character in Swift, so a CRLF file splits on it as well as on "\n"; a read
        // cut between the two leaves a "\r", which is dropped.
        var lines = decoded.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map { line in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        // A file that ends with its newline has no line after it.
        if lines.last?.isEmpty == true, !cut { lines.removeLast() }
        if lines.count > maximumLines {
            lines = Array(lines.prefix(maximumLines))
            cut = true
        }
        // A line longer than the cap is cut too, even when the whole file was read.
        if lines.contains(where: { $0.count > maximumLineLength }) { cut = true }
        return .success(Self(lines: lines.map { String($0.prefix(maximumLineLength)) }, truncated: cut))
    }
}

extension AgentPaneModel {
    /// `link.preview`: the first lines of the text file a path chip names. Inside the roots it is
    /// read; outside them only under `agentPane.links.outsideRoots = open` (the default), which
    /// treats an outside path as an inside one: `confirm` promises to ask before anything outside
    /// is opened, and a passive hover cannot ask. A deny-listed path is never read, checked again
    /// after symlinks and on the open handle. Every refusal of an outside path answers
    /// `pathOutsideRoots`, so the page learns nothing about a file it is not shown.
    ///
    /// A chat on another machine reads nothing here (the same guard as a reply image's,
    /// ``loadReplyImage(_:)``): its agent names paths on that machine, and a file here with the
    /// same spelling is not its file. It answers `{remote: true}`, so the card says where the file
    /// is instead of showing nothing. The read runs off the main actor, so the guard runs again
    /// after it: a chat that turned remote while it ran gets none of this Mac's lines.
    func previewReplyPath(_ text: String) async -> [String: Any] {
        guard !chatIsElsewhere else { return AgentPaneReply.success(["remote": true]) }
        let paths = replyPaths()
        guard let resolved = paths.resolve(text) else { return Self.replyFailure(.pathInvalid) }
        switch resolved.place {
        case .denied: return Self.replyFailure(.pathDenied)
        case .missing: return Self.replyFailure(.pathInvalid)
        case .root: break
        case .outside:
            guard replyLinks.settings().outsideRoots == .open else { return Self.replyFailure(.pathOutsideRoots) }
        }
        let refusal: AgentPaneReplyError = resolved.place == .outside ? .pathOutsideRoots : .pathInvalid
        guard let canonical = AcpmuxPathPolicy.canonical(resolved.path) else { return Self.replyFailure(refusal) }
        // A link may point a harmless name at a secret.
        guard !paths.isDenied(canonical) else { return Self.replyFailure(.pathDenied) }
        let inside = resolved.place == .root
        let accept: @Sendable (String) -> Bool = { real in !paths.isDenied(real) && (!inside || paths.isInsideRoot(real)) }
        let read = await replyLinks.readTextPreview(canonical, accept)
        guard !chatIsElsewhere else { return AgentPaneReply.success(["remote": true]) }
        switch read {
        case .success(let preview):
            return AgentPaneReply.success(["lines": preview.lines, "truncated": preview.truncated])
        case .failure:
            return Self.replyFailure(refusal)
        }
    }
}
