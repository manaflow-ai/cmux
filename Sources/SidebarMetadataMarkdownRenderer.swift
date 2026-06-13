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
    private static var cache: [String: AttributedString?] = [:]
    private static var insertionOrder: [String] = []
    private static let capacity = 512

    static func rendered(_ markdown: String) -> AttributedString? {
        if let hit = cache[markdown] {
            return hit
        }
        let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )
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
}
