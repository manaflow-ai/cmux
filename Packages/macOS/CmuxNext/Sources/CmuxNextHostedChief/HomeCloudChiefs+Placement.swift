public import CmuxNextHomeEngine

extension HomeCloudChiefs {
    /// The cloud Chief whose main conversation is `conversation`: its agent id and whether a
    /// paired server runs it, from the Chief tab's Chiefs, else from `records` (the directory's
    /// `chief.list`); nil while neither knows it.
    public func placement(of conversation: String, records: [HomeChiefRecord]) -> (id: String, placed: Bool)? {
        let request = ChiefRules.PlacementRequest(chiefs: self, conversation: conversation, records: records.map {
            .init(id: $0.id, mainConversation: $0.mainConversation, placed: $0.placed)
        })
        let placement = ChiefRules.rule("chiefs_placement", request, else: ChiefRules.PlacementReply()).placement
        return placement.map { ($0.id, $0.placed) }
    }
}
