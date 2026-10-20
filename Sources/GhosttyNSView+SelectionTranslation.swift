import AppKit
import GhosttyKit
import SwiftUI

extension GhosttyNSView {
    func addTranslateSelectionMenuItem(to menu: NSMenu, surface: ghostty_surface_t) {
        guard #available(macOS 15.0, *),
              TerminalSelectionTranslation.isSupported,
              let selectionText = readSelectionSnapshot(surface: surface)?.string,
              !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let translateItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.translateSelection", defaultValue: "Translate Selection"),
            action: #selector(translateCurrentSelection(_:)),
            keyEquivalent: ""
        )
        translateItem.target = self
        translateItem.image = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)
    }

    /// Presents the system Translation popover for the current selection.
    @available(macOS 15.0, *)
    @objc func translateCurrentSelection(_ sender: Any?) {
        #if canImport(Translation)
        guard let snapshot = readSelectionSnapshot(),
              !snapshot.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        selectionTranslationHostView?.removeFromSuperview()
        selectionTranslationHostView = nil

        let anchorHeight: CGFloat = 22
        let anchor = NSPoint(
            x: min(max(0, snapshot.topLeft.x), bounds.width - 1),
            y: min(max(0, bounds.height - snapshot.topLeft.y - anchorHeight), bounds.height - 1)
        )
        weak var hostRef: NSView?
        let host = NSHostingView(rootView: TerminalSelectionTranslationAnchorView(
            text: snapshot.string,
            onDismiss: { [weak self] in
                self?.removeSelectionTranslationHost(hostRef)
            }
        ))
        hostRef = host
        host.frame = NSRect(x: anchor.x, y: anchor.y, width: 2, height: anchorHeight)
        addSubview(host)
        selectionTranslationHostView = host
        #endif
    }

    private func removeSelectionTranslationHost(_ hostRef: NSView?) {
        guard let hostRef, selectionTranslationHostView === hostRef else { return }
        hostRef.removeFromSuperview()
        selectionTranslationHostView = nil
    }
}
