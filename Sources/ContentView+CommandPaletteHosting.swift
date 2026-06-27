import AppKit
import CmuxCommandPalette
import CmuxCommandPaletteUI
import SwiftUI

// Command-palette host-seam conformances for `ContentView`, relocated out of the
// ContentView god file. Only witnesses that read ContentView's NON-private state
// live here. Witnesses that touch ContentView's private members must stay inline
// in ContentView.swift, since `private` access is file-scoped: an extension in a
// separate file in the same module cannot see them. ContentView.swift therefore
// keeps those witnesses in plain `extension ContentView { ... }` blocks that
// satisfy the same protocol requirements.

extension ContentView: CommandPaletteListHost {
    func commandPaletteListBeep() {
        NSSound.beep()
    }

    func commandPaletteListAnimate(_ body: () -> Void) {
        withAnimation(.easeOut(duration: 0.1)) {
            body()
        }
    }
}

extension ContentView: CommandPaletteLifecycleHost {
    var commandPaletteLifecycleDefaultWorkspaceDescriptionHeight: CGFloat {
        CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    }

    func commandPaletteLifecycleClearForkableProbeActivePanelKey() {
        commandPaletteForkableAgentProbeCoordinator.activePanelKey = nil
    }

    func commandPaletteLifecycleDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(message())
#endif
    }
}
