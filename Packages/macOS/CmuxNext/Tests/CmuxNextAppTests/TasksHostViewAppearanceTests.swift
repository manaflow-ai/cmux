import AppKit
import CmuxNextDesign
import CmuxNextTasks
import Testing

/// The Tasks pane in the scheduler sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-340,
/// rule 9, the hidden class; recipe R-appear): a theme change while the pane is hidden resolves no colors (no view
/// apply); its show resolves them once, however many changes came while it was hidden. Before, every theme change
/// resolved the pane's colors and wrote them to its SwiftUI state, hidden or not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TasksHostViewAppearanceTests {
    @Test func aThemeChangeOfAHiddenTasksPaneResolvesItsColorsOnceOnShow() {
        _ = NSApplication.shared
        let host = TasksHostView(model: TasksModel(source: MockTasksSource()), layout: .fallback)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The window's node reads visible (the window is never ordered in), so the pane's node follows only its own hide.
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        let shown = host.colorResolves
        host.viewDidChangeEffectiveAppearance()
        #expect(host.colorResolves == shown + 1, "a shown Tasks pane did not resolve its colors on a theme change")

        host.isHidden = true
        let hidden = host.colorResolves
        host.viewDidChangeEffectiveAppearance()
        host.viewDidChangeEffectiveAppearance()
        #expect(host.colorResolves == hidden, "a hidden Tasks pane resolved its colors")
        host.isHidden = false
        #expect(host.colorResolves == hidden + 1, "the show resolved the hidden theme changes \(host.colorResolves - hidden) times (want 1)")
    }
}
