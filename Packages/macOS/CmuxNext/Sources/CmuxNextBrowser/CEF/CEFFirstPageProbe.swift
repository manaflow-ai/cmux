/// Asks the first Chromium page this launch that is ready for keys (loaded and painted) one script, once per
/// process (startup-tti: the first page's own navigation start, DOMContentLoaded and first contentful paint, which
/// `CmuxNextControl.LaunchFirstPage` writes and reads). The app owns the one probe and hands it each page as it
/// becomes ready; every page after the first costs one Bool read.
@MainActor
public final class CEFFirstPageProbe {
    private var asked = false

    public init() {}

    /// Evaluates `script` in `tab`'s isolated world the first time this is called, and hands `answer` the string
    /// the page returned. Nothing when the page answers no string or closes first.
    public func ask(_ tab: CEFTab, script: String, answer: @escaping @MainActor (String) -> Void) {
        guard !asked else { return }
        asked = true
        // task-owner: one bounded page evaluation per process; the tab's close fails it.
        Task { [weak tab] in
            guard let tab, case .string(let text)? = try? await tab.evaluate(script, world: .isolated, gesture: .cmux) else { return }
            answer(text)
        }
    }
}
