import Foundation

/// Local video and audio files the pane may play. The page's CSP loads media only from the pane's
/// own origin, so a checked file gets an unguessable `cmux-agent://pane/__media/<token>.<ext>` URL
/// that ``AgentPaneSchemeHandler`` serves in byte ranges. The page never names a file itself: it
/// asks `media.load` with the path from the reply, and the host checks it like a reply image.
final class AgentPaneMediaGrants {
    static let shared = AgentPaneMediaGrants()

    /// The extensions the pane plays, with the type each is served as.
    nonisolated static let types: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "flac": "audio/flac",
    ]
    /// Largest file the pane plays (it reads only the ranges the player asks for).
    nonisolated static let maximumBytes = 4 << 30
    /// Most files granted at once; the oldest grant goes first.
    static let maximumGrants = 256
    static let pathPrefix = "/__media/"

    private var files: [String: URL] = [:]
    private var tokens: [URL: String] = [:]
    private var order: [String] = []

    /// The URL the page plays `file` (canonical, already checked) by; the same file keeps its URL.
    func grant(_ file: URL) -> String {
        let name: String
        if let known = tokens[file] {
            name = known
        } else {
            name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "." + file.pathExtension.lowercased()
            files[name] = file
            tokens[file] = name
            order.append(name)
            if order.count > Self.maximumGrants, let oldest = order.first {
                order.removeFirst()
                if let gone = files.removeValue(forKey: oldest) { tokens[gone] = nil }
            }
        }
        return "\(AgentPaneSource.bundledScheme)://\(AgentPaneSource.bundledHost)\(Self.pathPrefix)\(name)"
    }

    /// The granted file a media URL names, nil for any other URL.
    func file(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == AgentPaneSource.bundledScheme,
              url.host?.lowercased() == AgentPaneSource.bundledHost,
              url.path.hasPrefix(Self.pathPrefix) else { return nil }
        return files[String(url.path.dropFirst(Self.pathPrefix.count))]
    }
}

extension AgentPaneModel {
    /// A video or audio file inside the roots, as a URL the pane plays. Web media is refused
    /// (the pane fetches nothing itself).
    func loadReplyMedia(_ src: String) async -> [String: Any] {
        if let scheme = URL(string: src)?.scheme?.lowercased(), scheme != "file" { return Self.replyFailure(.mediaRefused) }
        guard let resolved = replyPaths().resolve(src) else { return Self.replyFailure(.pathInvalid) }
        switch resolved.place {
        case .root: break
        case .denied: return Self.replyFailure(.pathDenied)
        case .outside: return Self.replyFailure(.pathOutsideRoots)
        case .missing: return Self.replyFailure(.pathInvalid)
        }
        let file = URL(fileURLWithPath: resolved.path)
        guard AgentPaneMediaGrants.types[file.pathExtension.lowercased()] != nil,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= AgentPaneMediaGrants.maximumBytes
        else { return Self.replyFailure(.mediaRefused) }
        return AgentPaneReply.success(["src": AgentPaneMediaGrants.shared.grant(file)])
    }
}
