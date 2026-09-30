import AppKit
import CmuxCommandPalette

/// The value snapshot of one window's command palette.
///
/// `ContentView` refreshes this value when it evaluates the palette. Keeping
/// the projection here gives both the SwiftUI list and socket reads one
/// window-scoped source of truth without making a socket request depend on a
/// mounted responder or a notification round trip.
@MainActor
final class PaletteAgentCommandsProvider {
    private(set) var snapshot: [CommandPaletteAgentCommand] = []

    func replace(
        with candidates: [CommandPaletteAgentCommandCandidate]
    ) {
        snapshot = CommandPaletteAgentSurface.app.commands(from: candidates)
    }
}

/// Owns the providers associated with live cmux windows.
@MainActor
final class PaletteAgentCommandsBroker {
    static let shared = PaletteAgentCommandsBroker()

    private final class WeakProvider {
        weak var value: PaletteAgentCommandsProvider?

        init(_ value: PaletteAgentCommandsProvider) {
            self.value = value
        }
    }

    private var providers: [ObjectIdentifier: WeakProvider] = [:]

    func register(_ provider: PaletteAgentCommandsProvider, for window: NSWindow) {
        providers[ObjectIdentifier(window)] = WeakProvider(provider)
    }

    func unregister(for window: NSWindow) {
        providers.removeValue(forKey: ObjectIdentifier(window))
    }

    func snapshot(for window: NSWindow) -> [CommandPaletteAgentCommand]? {
        let key = ObjectIdentifier(window)
        guard let provider = providers[key]?.value else {
            providers.removeValue(forKey: key)
            return nil
        }
        return provider.snapshot
    }
}
