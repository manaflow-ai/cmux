public import Foundation

/// Who is offered the debug-only actions (`ActionDescriptor.isDebugOnly`).
///
/// They exist only where developer tools do (`DevTools`: DEV and NIGHTLY). The person sees them only in
/// the Command Palette, and only while Settings > Development > Internal Developer Mode
/// (`app.internalDeveloperMode`) is on; a script (the CLI, MCP, the socket) runs them whenever developer
/// tools exist, the toggle aside. `isOn` is read when asked (each palette open, each key press), so a
/// change of the setting shows at the next open with no restart.
public nonisolated struct DebugActionGate {
    /// A debug-only action's title in the palette: "Debug: Tab Bar Playground" (`%@` is its name).
    public static var titleFormat: String {
        String(localized: "action.debug.titleFormat", defaultValue: "Debug: %@", bundle: .module)
    }

    /// This build has developer tools (`DevTools.isEnabled`; tests pass a Release bundle's answer).
    public var devTools: Bool
    /// Internal Developer Mode, read now (the App reads the setting; off by default).
    public var isOn: @MainActor () -> Bool

    public init(devTools: Bool = DevTools.isEnabled, isOn: @escaping @MainActor () -> Bool = { false }) {
        self.devTools = devTools
        self.isOn = isOn
    }

    /// Whether the person is offered them now: developer tools and the toggle on.
    @MainActor public var offeredToPerson: Bool { devTools && isOn() }
}
