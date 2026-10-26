/// The renderer a page may share with other pages, by capability (plans/cmux-next/chrome-parity/p13-webui.md
/// section 3.B). A page shares a process only with pages of its own group, as Chrome shares a top-chrome
/// WebUI renderer only among WebUI hosts of one lock (`chrome/browser/chrome_content_browser_client.cc`
/// `ShouldTryToUseExistingProcessHost`, `content/browser/site_info.cc` `IsWebUIAndUsesTLDForProcessLockURL`).
/// The group is the security boundary, so every ``PageDescriptor`` names one; a descriptor whose ops change
/// moves only after the capability test (task 087) agrees.
public nonisolated enum PageProcessGroup: String, Sendable, Hashable, CaseIterable {
    /// The agent page (New Tab and every chat): one origin and the same ops on every instance, as Chrome's
    /// NTP shares a renderer per site.
    case agent
    /// Pages that write app state and show no repository text or remote content (Settings, History).
    case privileged
    /// Pages that read or show repository text or remote images and have no host-power op (Markdown, Files).
    case viewer
    /// A page with a host-power op or remote content and no peer of its class (diff, editor, changelog):
    /// one process per page.
    case solo
    /// Passwords: never shares a process.
    case secrets

    /// Whether pages of this group may share one renderer with each other. `solo` and `secrets` keep one
    /// process per page.
    public var sharesRenderer: Bool {
        switch self {
        case .agent, .privileged, .viewer: true
        case .solo, .secrets: false
        }
    }
}
