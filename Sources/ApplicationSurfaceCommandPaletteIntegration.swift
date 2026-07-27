import AppKit
import CmuxCommandPalette

extension CommandPaletteCommandContribution {
    static var newApplicationPane: Self {
        Self(
            commandId: "palette.newApplicationPane",
            title: { _ in
                String(
                    localized: "command.newApplicationPane.title",
                    defaultValue: "New Application Pane"
                )
            },
            subtitle: { _ in
                String(
                    localized: "command.newApplicationPane.subtitle",
                    defaultValue: "Mirror and control a Mac window"
                )
            },
            keywords: [
                "new", "application", "app", "window", "pane", "capture",
                "screen", "mirror", "minecraft",
            ]
        )
    }
}

extension CommandPaletteHandlerRegistry {
    @MainActor
    mutating func registerNewApplicationPane(
        tabManager: TabManager,
        preferredWindow: @escaping @MainActor () -> NSWindow?
    ) {
        register(commandId: "palette.newApplicationPane") {
            AppDelegate.shared?.presentNewApplicationSurface(
                tabManager: tabManager,
                preferredWindow: preferredWindow()
            )
        }
    }
}
