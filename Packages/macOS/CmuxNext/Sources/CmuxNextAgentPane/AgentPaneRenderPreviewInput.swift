import Foundation

/// Shared capture limits, checked before a page or WebKit can allocate a preview.
struct AgentPaneRenderPreviewInput {
    let html: String
    let width: Int?

    init(html: String, width: Int?) throws {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              html.utf8.count <= 1 << 20, width.map({ (320...1440).contains($0) }) ?? true else {
            throw URLError(.badURL)
        }
        self.html = html
        self.width = width
    }
}
