public import AppKit

public extension NSWindow {
    /// Calls `change` when the keyboard leaves this window's family (the window, its child windows and sheets) after
    /// the family held it (true), and when it comes back (false); nil stops it. One watcher per window.
    ///
    /// The window's one key tracker reads the app's key and activation notices once per main-actor turn, so a watcher
    /// adds no observers of its own. A popup of the window's own (a child panel) taking the keys keeps them in the family.
    ///
    /// ```swift
    /// launcher.watchKeyFamily { [weak launcher] left in if left { launcher?.orderOut(nil) } }
    /// ```
    ///
    /// - Parameter change: Told true when the keyboard left the family, false when it came back.
    func watchKeyFamily(_ change: (@MainActor (Bool) -> Void)?) {
        WindowKeyFamily.of(self).onInactiveChange = change
    }
}
