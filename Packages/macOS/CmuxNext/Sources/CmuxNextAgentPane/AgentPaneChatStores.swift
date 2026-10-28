public import Foundation

/// What a chat keeps outside its pane, beside the launch snapshot: where its transcript rested
/// (``AgentPaneScrollAnchors``) and its unsent composer chips (``AgentPaneDraftAttachments``).
///
/// The App makes one per process from its state folder (`AgentTabStore.wired`) and hands it by init
/// to every agent pane, whose ``AgentPageProvider`` answers the page's ops with it; no store is a
/// process global. ``keepsNothing`` keeps nothing (a test host, the gallery). Making one touches no file:
/// each store reads its file at its first use.
///
/// ```swift
/// let stores = AgentPaneChatStores(directory: stateFolder)
/// let provider = AgentPageProvider(chatStores: stores, mainWork: mainThread.mainWork) { _ in model }
/// ```
@MainActor
public struct AgentPaneChatStores {
    /// Where each chat rested; nil keeps no places.
    public let scrollAnchors: AgentPaneScrollAnchors?
    /// Each chat's unsent chips; nil keeps no chips.
    public let draftAttachments: AgentPaneDraftAttachments?

    /// The given stores.
    ///
    /// - Parameters:
    ///   - scrollAnchors: Where each chat rested, or nil.
    ///   - draftAttachments: Each chat's unsent chips, or nil.
    public init(scrollAnchors: AgentPaneScrollAnchors?, draftAttachments: AgentPaneDraftAttachments?) {
        self.scrollAnchors = scrollAnchors
        self.draftAttachments = draftAttachments
    }

    /// Both stores, in `directory` (the folder of the launch snapshot).
    ///
    /// - Parameter directory: The app's state folder; the stores create nothing in it until they write.
    public init(directory: URL) {
        self.init(scrollAnchors: AgentPaneScrollAnchors(directory: directory),
                  draftAttachments: AgentPaneDraftAttachments(directory: directory))
    }

    /// No stores: the ops answer that nothing is kept.
    public static var keepsNothing: AgentPaneChatStores { AgentPaneChatStores(scrollAnchors: nil, draftAttachments: nil) }
}
