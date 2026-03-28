import AppKit

/// Protocol for renderers that transform fenced code blocks into images.
///
/// Conforming types handle a specific language tag (e.g., "mermaid", "graphviz")
/// and convert source code into rendered images via external CLI tools.
///
/// To add a new renderer:
/// 1. Create a class conforming to `FencedCodeRenderer`
/// 2. Register it in `FencedCodeRendererRegistry.shared` at app startup
///
/// The markdown panel will automatically detect fenced blocks matching
/// `languageTag` and route them through your renderer.
protocol FencedCodeRenderer: AnyObject {
    /// The fenced code block language identifier (e.g., "mermaid").
    var languageTag: String { get }

    /// Whether the external tool is installed and available.
    /// Must be safe to read from the main thread.
    @MainActor var isAvailable: Bool { get }

    /// Optional localized hint shown when the tool is not installed.
    @MainActor var installHint: String? { get }

    /// Generate a cache key for the given code and theme.
    func renderCacheKey(code: String, isDark: Bool) -> String

    /// Render fenced code to an image. Calls completion on the main thread.
    func render(code: String, isDark: Bool, completion: @escaping (NSImage?) -> Void)

    /// Cancel in-flight renders whose keys are not in the active set.
    func cancelRendersExcept(activeKeys: Set<String>)
}

/// Central registry of fenced code renderers keyed by language tag.
final class FencedCodeRendererRegistry {
    static let shared = FencedCodeRendererRegistry()

    private var renderers: [String: FencedCodeRenderer] = [:]

    private init() {}

    /// Register a renderer for its language tag.
    func register(_ renderer: FencedCodeRenderer) {
        renderers[renderer.languageTag] = renderer
    }

    /// Look up a renderer by language tag.
    func renderer(for tag: String) -> FencedCodeRenderer? {
        renderers[tag.lowercased()]
    }

    /// Set of all registered language tags.
    var supportedTags: Set<String> {
        Set(renderers.keys)
    }
}
