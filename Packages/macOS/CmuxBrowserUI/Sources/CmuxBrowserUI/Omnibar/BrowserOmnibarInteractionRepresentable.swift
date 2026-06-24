public import AppKit
public import SwiftUI

/// `NSViewRepresentable` bridge that mounts ``BrowserOmnibarInteractionView`` in
/// the SwiftUI omnibar, forwarding the panel id and the injected registry.
@MainActor
public struct BrowserOmnibarInteractionRepresentable: NSViewRepresentable {
    let panelId: UUID
    let nativeFieldRegistry: BrowserOmnibarNativeFieldRegistry

    public init(panelId: UUID, nativeFieldRegistry: BrowserOmnibarNativeFieldRegistry) {
        self.panelId = panelId
        self.nativeFieldRegistry = nativeFieldRegistry
    }

    public func makeNSView(context: Context) -> BrowserOmnibarInteractionView {
        let view = BrowserOmnibarInteractionView(frame: .zero)
        view.panelId = panelId
        view.nativeFieldRegistry = nativeFieldRegistry
        return view
    }

    public func updateNSView(_ nsView: BrowserOmnibarInteractionView, context: Context) {
        nsView.panelId = panelId
        nsView.nativeFieldRegistry = nativeFieldRegistry
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
