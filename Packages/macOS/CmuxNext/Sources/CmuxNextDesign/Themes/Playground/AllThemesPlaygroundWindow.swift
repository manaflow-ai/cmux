public import AppKit
public import Foundation
import SwiftUI

/// The All Themes playground's window (`debug.allThemesPlayground`, Debug menu > All Themes
/// Playground, DEV and NIGHTLY): ``show()`` opens ``AllThemesPlaygroundView`` in its own window,
/// or raises it when open. The action holds one; the window lives as long as it does.
@MainActor public final class AllThemesPlaygroundWindow {
    private let folders: [URL]
    private var window: NSWindow?

    /// A playground of the theme files in `folders`.
    /// - Parameter folders: Theme folders, such as the app's `Resources/ghostty/themes`.
    public init(folders: [URL]) {
        self.folders = folders
    }

    /// Opens the playground window (reading every theme the first time), or brings it to the front.
    public func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = AllThemesPlaygroundStrings.windowTitle
        window.isReleasedWhenClosed = false
        let model = AllThemesPlaygroundModel()
        window.contentView = NSHostingView(rootView: AllThemesPlaygroundView(model: model))
        let folders = folders
        Task { await model.load(folders: folders) }
        window.center()
        return window
    }
}
