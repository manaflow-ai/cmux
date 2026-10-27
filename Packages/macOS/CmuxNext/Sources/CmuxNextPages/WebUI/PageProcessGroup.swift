import Foundation

/// The renderer a first-party page shares (plans/cmux-next/chrome-parity/p13-webui.md 3.B). Chrome lets
/// WebUI pages share a renderer only when their process lock says so (`content/browser/site_info.cc`,
/// `IsWebUIAndUsesTLDForProcessLockURL`), and keeps untrusted content in `chrome-untrusted://` documents,
/// never in a process with stronger bindings (`content/public/common/url_constants.h`,
/// `kChromeUIUntrustedScheme`). A cmux group is the same rule: pages share only with pages of their
/// ``PageCapability/Class``, which ``PageProcessGroupAudit`` checks.
public nonisolated enum PageProcessGroup: String, Sendable, Hashable, CaseIterable {
    /// The agent page: New Tab and every chat, one origin.
    case agent
    /// Pages that write app state and show only app data.
    case privileged
    /// Pages that show repository files or remote content and only read.
    case viewer
    /// Host power, undeclared ops, or outside content with actions: one renderer each.
    case solo
    /// Stored secrets: one renderer each, never shared.
    case secrets

    /// Whether the group's pages share one renderer; `solo` and `secrets` pages each get their own.
    public var sharesRenderer: Bool {
        switch self {
        case .agent, .privileged, .viewer: true
        case .solo, .secrets: false
        }
    }
}

/// What a compromised renderer could reach through one page, computed from its descriptor and the
/// descriptor's ``PageOpTable``s: a page's ops are only as safe as the least trusted content in its
/// process, because a renderer that runs hostile content can send any message any of its frames may
/// send (Chrome's site isolation threat model, docs/security/compromised-renderers.md).
public nonisolated struct PageCapability: Sendable, Hashable {
    /// The capability class; pages share a renderer only within one class.
    public nonisolated enum Class: Sendable, Hashable, CustomStringConvertible {
        /// Shows only app data and reaches no host power or secret.
        case appContent
        /// Shows repository files or remote content, and every op it may call only reads.
        case outsideContent
        /// Shows outside content and acts (a registry action, a confirmed op, or a namespace op of
        /// kind ``PageOpTable/Kind/act``): shares only with other instances of `page`, so outside
        /// content never drives another page's actions.
        case outsideContentWithActions(page: String)
        /// Reaches host power (shell, git push, commit or worktree, file save, harness, transport):
        /// shares only with other instances of `page`.
        case hostPower(page: String)
        /// Has a namespace with no ``PageOpTable``, so what it reaches is unknown: shares only with
        /// other instances of `page`.
        case undeclaredOps(page: String)
        /// Reaches stored secrets or the daemon's credential: shares only with other instances of `page`.
        case secrets(page: String)

        public var description: String {
            switch self {
            case .appContent: "app content"
            case .outsideContent: "outside content"
            case .outsideContentWithActions(let page): "outside content with actions of \(page)"
            case .hostPower(let page): "host power of \(page)"
            case .undeclaredOps(let page): "undeclared ops of \(page)"
            case .secrets(let page): "secrets of \(page)"
            }
        }
    }

    /// Op prefixes that hand a page a stored secret or a token that opens the daemon.
    public static let secretPrefixes: [String] = ["cmux.passwords.", "cmux.host.credential."]
    /// Dynamic resource prefixes whose bytes the app makes itself: the markdown page's bundled
    /// libraries (``MarkdownPageResource/library``), the App Store's glyphs
    /// (``AppsPageNativeOps/glyphPrefix``), the icon picker's SF Symbols (`IconPickerSymbols.prefix`),
    /// and Settings' backdrop thumbnails and stored icons, which the host draws as PNG
    /// (`SettingsBackdropThumbnails.prefix`, `SettingsIconAssets.prefix`). Every other prefix is
    /// outside content (fail closed); CmuxNextAppTests' PageProcessGroupTableTests ties each name to
    /// its source.
    public static let appOnlyPrefixes: Set<String> = [
        MarkdownPageResource.library, AppsPageNativeOps.glyphPrefix, "__symbol", "backdrop", "icon",
    ]

    /// The descriptor id.
    public let page: String
    /// The admitted ops that act on the host as the person, sorted.
    public let hostPowerOps: [String]
    /// The namespaces with no ``PageOpTable``, sorted.
    public let undeclaredNamespaces: [String]
    /// The namespaces and ops that reach a secret, sorted.
    public let secretOps: [String]
    /// What the page shows from outside the app: remote CSP sources (`media-src https://...`), dynamic
    /// prefixes not in ``appOnlyPrefixes``, and `shown text` when the owner says the page shows
    /// outside text.
    public let outsideSources: [String]
    /// What it does besides reading: registry actions it runs through `cmux.app.action.run`
    /// (`action:<id>`), confirmed ops (`confirmed:<op>`) and admitted namespace ops of kind
    /// ``PageOpTable/Kind/act``, sorted.
    public let actingOps: [String]
    /// Everything the page may reach: each undeclared `namespace*`, native ops, declared ops with
    /// their kind (`cmux.files.list (read)`), `action:<id>` and `confirmed:<op>`, sorted. The audit
    /// prints it for each page of a failing group.
    public let ops: [String]
    /// The class the facts above put the page in.
    public let capabilityClass: Class

    /// - Parameters:
    ///   - descriptor: The page; its ``PageDescriptor/opTables`` say what each namespace op does.
    ///   - showsOutsideText: The page shows repository files or remote text that its CSP and dynamic
    ///     prefixes do not reveal (a file tree, pull request titles, agent output).
    public init(_ descriptor: PageDescriptor, showsOutsideText: Bool = false) {
        page = descriptor.id
        let undeclared = descriptor.namespaces.filter { descriptor.opTable(for: $0) == nil }
        undeclaredNamespaces = undeclared.sorted()
        var declared: [String: PageOpTable.Kind] = [:]
        for table in descriptor.opTables where descriptor.namespaces.contains(table.namespace) {
            for (op, kind) in table.kinds where descriptor.admits(op) { declared[op] = max(declared[op] ?? kind, kind) }
        }
        // An undeclared namespace still names the host-power ops known to live under it.
        let knownUnder = PageOpTable.hostPowerOps.filter { op in
            descriptor.admits(op) && undeclared.contains { op.hasPrefix($0) }
        }
        hostPowerOps = (Array(declared.filter { $0.value == .hostPower }.keys) + knownUnder).sorted()
        let reachable: [String] = descriptor.namespaces + Array(descriptor.nativeOps) + Array(declared.keys)
        secretOps = Set(reachable.filter { name in
            Self.secretPrefixes.contains { name.hasPrefix($0) || (name.hasSuffix(".") && $0.hasPrefix(name)) }
        }).sorted()
        let csp = descriptor.csp
        let own = descriptor.origin.lowercased()
        let directives: [(name: String, sources: [String])] = [("connect-src", csp.connect), ("frame-src", csp.frame), ("media-src", csp.media)]
        let remote: [String] = directives.flatMap { directive in
            directive.sources.filter { !["'none'", "'self'", own].contains($0.lowercased()) }.map { "\(directive.name) \($0)" }
        }
        let prefixes = descriptor.dynamicPrefixes.subtracting(Self.appOnlyPrefixes).sorted().map { "resource \($0)" }
        outsideSources = remote.sorted() + prefixes + (showsOutsideText ? ["shown text"] : [])
        let actions = descriptor.nativeOps.contains(PageNativeOp.actionRun) ? descriptor.actions.map { "action:" + $0 } : []
        let confirmed = descriptor.confirmedOps.keys.map { "confirmed:" + $0 }
        actingOps = (actions + confirmed + Array(declared.filter { $0.value == .act }.keys)).sorted()
        var ops: [String] = undeclared.map { $0 + "*" }
        ops += descriptor.nativeOps
        ops += declared.map { "\($0.key) (\($0.value))" }
        ops += descriptor.actions.map { "action:" + $0 }
        ops += confirmed
        self.ops = ops.sorted()
        capabilityClass = if !secretOps.isEmpty {
            .secrets(page: descriptor.id)
        } else if !hostPowerOps.isEmpty {
            .hostPower(page: descriptor.id)
        } else if !undeclared.isEmpty {
            .undeclaredOps(page: descriptor.id)
        } else if !outsideSources.isEmpty {
            actingOps.isEmpty ? .outsideContent : .outsideContentWithActions(page: descriptor.id)
        } else {
            .appContent
        }
    }

    /// One line per page: its class, why, and every op it may reach.
    public var summary: String {
        var why: [String] = []
        if !secretOps.isEmpty { why.append("secrets: " + secretOps.joined(separator: ", ")) }
        if !hostPowerOps.isEmpty { why.append("host power: " + hostPowerOps.joined(separator: ", ")) }
        if !undeclaredNamespaces.isEmpty { why.append("undeclared: " + undeclaredNamespaces.joined(separator: ", ")) }
        if !outsideSources.isEmpty { why.append("outside: " + outsideSources.joined(separator: ", ")) }
        if !outsideSources.isEmpty, !actingOps.isEmpty { why.append("actions: " + actingOps.joined(separator: ", ")) }
        let reason = why.isEmpty ? "" : " [\(why.joined(separator: "; "))]"
        return "\(page) (\(capabilityClass))\(reason) ops: \(ops.joined(separator: ", "))"
    }
}

/// Checks a group table (p13-webui.md 3.B, task 087): a renderer that shares pages may hold only pages
/// of one ``PageCapability/Class``. So a host-power, secrets or undeclared page, or one that acts while
/// it shows outside content, shares only with its own instances, and a page that shows outside content
/// never shares with a page that shows only app data.
public nonisolated struct PageProcessGroupAudit: Sendable {
    /// A sharing group whose pages are of more than one class.
    public nonisolated struct Violation: Sendable, Hashable, CustomStringConvertible {
        public let group: PageProcessGroup
        public let pages: [PageCapability]

        /// The group, its classes, then each page's ``PageCapability/summary`` (its ops).
        public var description: String {
            let classes = Set(pages.map(\.capabilityClass.description)).sorted()
            let lines = pages.map { "  " + $0.summary }
            return (["group \(group.rawValue) mixes \(classes.joined(separator: ", ")):"] + lines).joined(separator: "\n")
        }
    }

    /// The failing groups, in ``PageProcessGroup/allCases`` order.
    public let violations: [Violation]

    public init(_ groups: [PageProcessGroup: [PageCapability]]) {
        violations = PageProcessGroup.allCases.compactMap { group -> Violation? in
            guard group.sharesRenderer, let pages = groups[group], Set(pages.map(\.capabilityClass)).count > 1 else {
                return nil
            }
            return Violation(group: group, pages: pages)
        }
    }

    /// Every violation's description, blank-line separated; empty when the table passes.
    public var report: String { violations.map(\.description).joined(separator: "\n\n") }
}
