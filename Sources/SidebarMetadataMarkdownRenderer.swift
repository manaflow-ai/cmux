import CmuxTerminalCore
import Foundation

/// Renders sidebar metadata-block markdown with a bounded memo cache so the
/// FIRST render of a row is already attributed.
///
/// The previous flow parsed in the row's `onAppear` into `@State`: every first
/// appearance of every metadata block performed a guaranteed nil -> attributed
/// swap, changing the row's intrinsic height mid-scroll and re-feeding the
/// sidebar-wide layout/measurement cycle
/// (https://github.com/manaflow-ai/cmux/issues/5764,
/// https://github.com/manaflow-ai/cmux/issues/5845). Lazy rows must be
/// height-stable after they appear, and row state belongs in the initializer or
/// the model, not `onAppear`.
///
/// Parsing inline from `body` matches the `SidebarWorkspaceDescriptionText`
/// sibling; the cache keeps repeat body evaluations cheap (agent-heavy rows
/// re-evaluate often) and is bounded so long sessions with churning metadata
/// cannot grow it without limit.
@MainActor
enum SidebarMetadataMarkdownRenderer {
    /// Keyed on the markdown alone, which is every input ``parse`` has today.
    /// Linkification passes a `nil` repository, so two rows with the same text
    /// always render the same. Giving `parse` a real repository means giving
    /// this key one too, or two workspaces in different repositories with
    /// identical metadata will serve each other's links.
    private static var cache: [String: AttributedString?] = [:]
    private static var insertionOrder: [String] = []
    private static let capacity = 512
    /// Only small blocks are rendered as markdown. Metadata markdown is
    /// agent/control-socket supplied and uncapped at this boundary. Caching
    /// large values would retain hundreds of big payloads after the workspace
    /// metadata is overwritten or cleared (memory), and parsing them inline on
    /// every body eval would re-run main-actor Markdown parsing under agent
    /// churn (CPU). Above this size the block falls back to plain text (the row
    /// renders `Text(block.markdown)` on the nil return): no parse, no
    /// retention, and still height-stable because the result never changes for
    /// a given block. Cached small blocks bound total retained bytes to
    /// `capacity * maxCacheableBytes`. A >4 KB sidebar metadata block is already
    /// pathological, so plain text is an acceptable degradation.
    private static let maxCacheableBytes = 4096

    static func rendered(_ markdown: String) -> AttributedString? {
        guard markdown.utf8.count <= maxCacheableBytes else {
            return nil
        }
        if let hit = cache[markdown] {
            return hit
        }
        let parsed = parse(markdown)
        if insertionOrder.count >= capacity, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        // updateValue, not subscript assignment: with an Optional value type,
        // `cache[markdown] = nil` removes the key instead of caching the failed
        // parse, so unparseable blocks would re-parse on every body eval and
        // append phantom keys to insertionOrder.
        cache.updateValue(parsed, forKey: markdown)
        insertionOrder.append(markdown)
        return parsed
    }

    /// Linkifies GitHub references the parser leaves as plain text.
    ///
    /// Only `owner/repo#123` resolves here, because that is the one form that
    /// names its own repository. A bare `#123`, a `GH-123` and a commit SHA all
    /// need to know which repository the row is about, and
    /// ``SidebarWorkspaceSnapshotBuilder`` carries no slug:
    /// `PullRequestProbeService` resolves one per workspace on every probe cycle
    /// and drops it at the package boundary, so bringing it through is the
    /// change that turns those three on.
    private static let linkifier = GitHubReferenceAttributedStringLinkifier()

    private static func parse(_ markdown: String) -> AttributedString? {
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ) else {
            return nil
        }
        // Inside `parse`, so the memo covers it and a row that re-evaluates its
        // body does not re-scan. Linkifying changes attributes only, so the
        // height stability this whole type exists for is untouched.
        return linkifier.linkifying(parsed, repositorySlug: nil)
    }
}
