import AppKit

extension SidebarView {
    /// Diagnostic: the model's list sections, the blocks the list draws and their heights.
    public func debugBlocksReport() -> [String: Any] {
        [
            "model_sections": model.sections.map { "\($0.id):\($0.nodes.count)" },
            "blocks": list.blocks.map { Array($0.sections.keys).sorted() } ?? [],
            "block_app_heights": list.blocks.map { $0.appHeights.map { "\($0.key.rawValue)=\($0.value)" } } ?? [],
            "block_heights": list.blockHeights(includeGap: false).map { "\($0.key)=\($0.value)" },
            "doc_drag": model.docDrag != nil,
            "doc_document": model.docDrag?.document != nil,
            "bands_below": model.layout.bands(room: model.activeProfileID?.rawValue).below.map { "\($0.id.rawValue):\($0.region.rawValue):\($0.content)" },
        ]
    }
}
