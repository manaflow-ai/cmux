import CmuxMobileShell

/// Store-isolated actions emitted by Pane Rack chrome.
struct PaneRackActions {
    let stagePane: (String) -> Void
    let selectTab: (_ surfaceID: String, _ paneID: String) -> Void
    let createTab: (String) async -> Result<Void, PaneRackMutationFailure>
    let closeTab: (String) async -> Result<Void, PaneRackMutationFailure>
    let setTailInterest: (Set<String>) -> Void
    let setPeekBudget: (_ surfaceID: String, _ rows: Int) -> Void
}
