import CmuxNextCompat
import CmuxNextPages
import Foundation

/// The agent page's generated resources on the page host (``PageDescriptor/agent``'s dynamic
/// prefixes), as a Chromium WebUI controller owns its page's URL data source
/// (content/public/browser/url_data_source.h):
/// - `__lib/<name>`: the chart and diagram libraries (Vega and Vega-Lite, Ondine, and Mermaid 11
///   as Ondine's fallback), the markdown viewer's bytes (``MarkdownPageResource/library(_:in:runner:)``).
/// - `__media/<token>.<ext>`: a video or audio file the host granted (``AgentPaneMediaGrants``), in
///   the byte ranges the player asks for, at most ``mediaChunk`` bytes per answer.
/// - `__render/frame`: the render card's frame document (``AgentPaneRenderFrame``).
final class AgentPageResources: PageDynamicResourceSource {
    /// The prefixes it answers, for the descriptor.
    nonisolated static let prefixes: Set<String> = [MarkdownPageResource.library, AgentPaneMediaGrants.prefix,
                                                    AgentPaneRenderFrame.prefix]
    /// The libraries the pane loads.
    nonisolated static let libraries: Set<String> = ["vega.js", "ondine.js", "mermaid.js"]
    /// Bytes one media answer carries at most; the player asks for the next range.
    nonisolated static let mediaChunk = 8 << 20

    /// The markdown viewer's bundled libraries; nil (a test, a broken bundle) answers no library.
    let libraryFolder: URL?
    /// The files the page may play.
    let grants: AgentPaneMediaGrants
    /// The app's blocking-work lanes: every library and media read runs on its files lane, never on the pool.
    let runner: any MayBlockRunner

    init(libraryFolder: URL? = Bundle.main.resourceURL.map(PageDescriptor.markdownLibraries(inAppResources:)),
         grants: AgentPaneMediaGrants = .shared, runner: any MayBlockRunner) {
        self.libraryFolder = libraryFolder
        self.grants = grants
        self.runner = runner
    }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard request.path.count == 1, let name = request.path.first else { return nil }
        switch request.prefix {
        case MarkdownPageResource.library:
            guard Self.libraries.contains(name), let folder = libraryFolder,
                  let data = await MarkdownPageResource.library(name, in: folder, runner: runner) else { return nil }
            return PageResource(data: data, mimeType: "text/javascript")
        case AgentPaneMediaGrants.prefix:
            guard let file = grants.file(named: name) else { return nil }
            return await Self.readSlice(of: file, range: request.range, on: runner)
        case AgentPaneRenderFrame.prefix:
            return name == AgentPaneRenderFrame.name ? AgentPaneRenderFrame.resource : nil
        default:
            return nil
        }
    }

    /// Reads the slice on `runner`'s files lane (the player waits for it); nil when the lane refused it (quit began).
    nonisolated static func readSlice(of file: URL, range: String?, on runner: any MayBlockRunner) async -> PageResource? {
        (try? await runner.runFiles(.userVisible) { mediaSlice(of: file, range: range) }) ?? nil
    }

    /// The part of `file` an HTTP `Range` header asks for (`bytes=a-b`, `bytes=a-` or `bytes=-n`),
    /// at most ``mediaChunk`` bytes: 200 for the whole file, 206 for a range, 416 past the end. Nil
    /// when the file cannot be read or is no longer the regular file that was granted (a link
    /// swapped in after the grant).
    nonisolated static func mediaSlice(of file: URL, range: String?) -> PageResource? {
        guard let values = try? file.blockingResourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize
        else { return nil }
        let type = AgentPaneMediaGrants.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        var lower = 0, upper = size - 1
        if let range {
            guard let (start, end) = byteRange(range, size: size), start < size else {
                return PageResource(data: Data(), mimeType: type, status: 416, contentRange: "bytes */\(size)",
                                    acceptsRanges: true)
            }
            lower = start
            upper = min(end, size - 1)
        }
        upper = min(upper, lower + mediaChunk - 1)
        let partial = range != nil || upper < size - 1
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(lower))) != nil,
              let data = size == 0 ? Data() : try? handle.blockingRead(upToCount: upper - lower + 1) else { return nil }
        return PageResource(data: data, mimeType: type, status: partial ? 206 : 200,
                            contentRange: partial ? "bytes \(lower)-\(lower + data.count - 1)/\(size)" : nil,
                            acceptsRanges: true)
    }

    /// The first and last byte a `Range` header names, nil for a header this does not read.
    nonisolated static func byteRange(_ header: String, size: Int) -> (Int, Int)? {
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes="), !spec.contains(",") else { return nil }
        let parts = spec.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let first = parts[0].trimmingCharacters(in: .whitespaces), last = parts[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let count = Int(last), count > 0 else { return nil }
            return (max(0, size - count), size - 1)
        }
        guard let start = Int(first), start >= 0 else { return nil }
        if last.isEmpty { return (start, size - 1) }
        guard let end = Int(last), end >= start else { return nil }
        return (start, end)
    }
}
