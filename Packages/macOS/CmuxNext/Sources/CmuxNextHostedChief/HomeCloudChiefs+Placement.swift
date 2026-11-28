public import CmuxNextHomeEngine

extension HomeCloudChiefs {
    /// The cloud Chief whose main conversation is `conversation`: its agent id and whether a
    /// paired server runs it, from the Chief tab's Chiefs, else from `records` (the directory's
    /// `chief.list`); nil while neither knows it.
    public func placement(of conversation: String, records: [HomeChiefRecord]) -> (id: String, placed: Bool)? {
        if let chief = chief(for: conversation) { return (chief.id, chief.brainPlace != nil) }
        return records.first { $0.mainConversation == conversation }.map { ($0.id, $0.placed) }
    }
}
