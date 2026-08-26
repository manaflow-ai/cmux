struct LinksPanelRowActions {
    var openPreferred: () -> Void
    var openBuiltIn: () -> Void
    var openExternal: () -> Void
    var copy: () -> Void
    var reveal: () -> Void
    var remove: () -> Void
    var clearAll: () -> Void
    var fetchTitle: (WorkspaceCapturedLink) async -> Void
}
