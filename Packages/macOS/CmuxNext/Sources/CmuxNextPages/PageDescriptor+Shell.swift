public import Foundation

public extension PageDescriptor {
    /// The page shell's entry html inside the one webviews-app build (webviews/shell-page.html).
    static let shellEntry = "shell-page.html"

    /// The page shell (plans/cmux-next/react-pages.md "Page shell"): one prewarmed document at
    /// `cmux-page://cmux.shell/` that mounts first-party pages (``inShell``) on `page.claim` with no
    /// navigation. It has no ops of its own; a claim binds the claimed page's descriptor. Its CSP is
    /// the strictest policy every shell page needs (strict: no page in it needs more).
    static let shell = PageDescriptor(
        id: "cmux.shell", resource: diffResource, namespaces: [], commands: [], entry: shellEntry)

    /// The shell's probe page (webviews/src/pages/shell/probe.ts): it exposes its context to the
    /// page world, for the reset tests and the claim bench. No provider serves its namespace.
    static let shellProbe = PageDescriptor(
        id: "cmux.shell.probe", resource: "shell-probe", namespaces: ["cmux.shell.probe."], inShell: true)

    /// First-party pages with a document of their own that a pooled host may navigate to; the
    /// pooled host's scheme handler serves each by host with its own CSP.
    static let navigablePages: [PageDescriptor] = [.shell, .diff, .markdown, .settings, .history, .cloud]

    /// The one call the app makes at launch: registers the app bundle's webviews-app directory as
    /// the shell's root (``PageID/registerBundledRoot(_:for:)``, the first registration wins).
    @discardableResult
    static func registerShellRoot(appResources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let appResources else { return nil }
        let root = diffRoot(inAppResources: appResources)
        PageID.registerBundledRoot(root, for: shell.id)
        return root
    }

    /// What this document serves while `claimed` is mounted in it: this origin, entry and CSP, with
    /// the claimed page's dynamic prefixes (its generated resources under the shell origin).
    func serving(_ claimed: PageDescriptor) -> PageDescriptor {
        PageDescriptor(id: id, resource: resource, namespaces: [], commands: [], csp: csp, entry: entry,
                       dynamicPrefixes: claimed.id == id ? dynamicPrefixes : claimed.dynamicPrefixes)
    }
}
