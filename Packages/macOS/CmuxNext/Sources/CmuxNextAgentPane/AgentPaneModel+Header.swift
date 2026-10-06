extension AgentPaneModel {
    /// The app actions the chat header runs on its tab (`pane.action`): the Terminal and Browser
    /// splits and the "..." menu's tab verbs.
    public static let headerActions: Set<String> = [
        "splitRight", "splitBrowserRight", "renameTab", "palette.toggleTabPin",
        "moveSurfaceToPaneRight", "palette.moveTabToNewWorkspace", "closeTab",
    ]
}
