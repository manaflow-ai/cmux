import CmuxBrowser
import CmuxTerminalCore

extension TerminalBrowserHostNormalizer {
    /// Terminal text without a scheme is a web host only under a real
    /// top-level domain, read from the system's Public Suffix List.
    func isPublicTopLevelDomain(_ label: String) -> Bool {
        BrowserReplPublicSuffixList.system.isTopLevelDomain(label)
    }
}
