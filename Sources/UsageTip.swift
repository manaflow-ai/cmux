struct UsageTip: Identifiable, Equatable {
    let id: UsageTipID
    let title: String
    let body: String
    let shortcutAction: KeyboardShortcutSettings.Action
}
