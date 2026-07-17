import Foundation

/// One web extension that can be loaded into the browser.
struct BrowserWebExtensionCandidate: Identifiable, Hashable, Sendable {
    /// Stable identity used for the enabled-set in settings: the appex plugin
    /// identifier for Safari extensions, or the directory path for unpacked ones.
    let id: String
    let kind: BrowserWebExtensionCandidateKind
    let path: String
    let version: String?
    let displayName: String?
}
