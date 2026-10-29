import CmuxNextPalette

/// Go to What Needs Me's rows, read from the marked tabs at each load (open, and each reload on a
/// change), never a list taken when the page opened.
@MainActor
final class AttentionPaletteProvider: PaletteProvider {
    let id = AttentionPalettePage.pageID
    private let page: AttentionPalettePage

    init(page: AttentionPalettePage) {
        self.page = page
    }

    // A palette reset can release a provider off the main actor (TabPaletteProvider, #17590).
    nonisolated deinit {}

    var immediateItems: [PaletteItem]? { page.rows() }
    func items() async -> [PaletteItem] { page.rows() }
}
