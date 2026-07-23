import AppKit

@MainActor
struct CommandPaletteAuthActions {
    let isAuthenticated: Bool
    let isWorking: Bool
    let beginSignIn: @MainActor (NSWindow) -> Bool
    let signOut: @MainActor () async -> Void
}
