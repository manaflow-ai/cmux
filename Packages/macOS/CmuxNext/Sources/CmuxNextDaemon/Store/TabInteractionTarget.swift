/// A click or key in a window went into a tab in the workspace shown there: the tab, the store
/// of that workspace's owning machine (so identical ids on different machines cannot cross-clear)
/// and the attention mark it showed when pressed.
@MainActor
public struct TabInteractionTarget {
    public let tab: TabModel
    public let store: DaemonStore
    public let local: Bool
    public let attentionRequestID: String?
    /// A mark from a daemon without request ids has only this client's generation to say
    /// it is still the mark pressed.
    public let attentionGeneration: UInt64

    public init(tab: TabModel, store: DaemonStore, local: Bool) {
        self.tab = tab
        self.store = store
        self.local = local
        attentionRequestID = tab.attention?.requestID
        attentionGeneration = tab.attentionGeneration
    }

    /// Whether the tab still shows the mark it showed when pressed.
    public var attentionUnchanged: Bool {
        guard tab.attention?.requestID == attentionRequestID else { return false }
        return attentionRequestID != nil || tab.attentionGeneration == attentionGeneration
    }
}
