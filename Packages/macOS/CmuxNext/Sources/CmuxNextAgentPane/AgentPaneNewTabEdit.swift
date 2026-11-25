/// What the New Tab page changed about itself; the App saves it as Settings would. The style
/// switch's pick (`newTab.setTemplate`).
public nonisolated enum AgentPaneNewTabEdit: Sendable, Equatable {
    /// The style switch (`{template}`): the template to save as `tabs.newTabTemplate` (the App
    /// checks the value).
    case template(String)

    /// The page method that sent it.
    var method: String { "newTab.setTemplate" }
}
