import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// The web links of a workspace's status entries (Open All Workspace PR
/// Links): the `pr` entry's first (`cmux workspace status set pr <text>`),
/// then the other entries', in order, each link once. Only http and https.
struct WorkspacePullRequestLinks {
    let urls: [URL]

    init(_ entries: [WorkspaceStatus.Entry]) {
        let ordered = entries.filter { $0.key == SidebarMapping.pullRequestKey } + entries.filter { $0.key != SidebarMapping.pullRequestKey }
        var seen = Set<String>()
        var urls: [URL] = []
        for entry in ordered {
            for url in Self.links(in: entry.text) where seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        self.urls = urls
    }

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.blockingRegexMatches(in: text, range: range).compactMap(\.url).filter { ["http", "https"].contains($0.scheme?.lowercased()) }
    }
}
