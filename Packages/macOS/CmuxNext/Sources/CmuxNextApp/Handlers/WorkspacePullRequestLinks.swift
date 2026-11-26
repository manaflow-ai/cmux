import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWindowRules
import Foundation

/// The web links of a workspace's status entries (Open All Workspace PR
/// Links): the `pr` entry's first (`cmux workspace status set pr <text>`),
/// then the other entries', in order, each link once. Only http and https.
struct WorkspacePullRequestLinks {
    let urls: [URL]

    init(_ entries: [WorkspaceStatus.Entry]) {
        // Rust's `handlers_verbs::pr_links` orders, filters and dedupes what the detector finds.
        let found = entries.map { WindowRules.StatusLinks(key: $0.key, links: Self.links(in: $0.text)) }
        urls = WindowRules().prLinks(found, prKey: SidebarMapping.pullRequestKey).compactMap(URL.init(string:))
    }

    private static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url?.absoluteString)
    }
}
