/// Selects the renderer for a workspace row in the AppKit-backed sidebar list.
enum SidebarWorkspaceRowPresentation: Equatable {
    case hostedSessionCard
    case nativeWorkspace

    static func resolve(hasSessionCard: Bool) -> Self {
        hasSessionCard ? .hostedSessionCard : .nativeWorkspace
    }

    var usesNativeChrome: Bool {
        self == .nativeWorkspace
    }
}
