import AppKit
import CmuxNextDesign
import CmuxNextTasks
import Testing

/// The Tasks pane in the scheduler sweep (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9, the hidden class): the pane resolves its colors in one place, `updateLayer`. A real appearance change
/// while the pane is hidden resolves no colors (AppKit does not display a hidden view); its show resolves them once,
/// however many changes came while it was hidden. Before, `viewDidChangeEffectiveAppearance` resolved them too, so
/// every theme change resolved the colors twice, one of them while hidden.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TasksHostViewAppearanceTests {
    @Test func aThemeChangeOfAHiddenTasksPaneResolvesItsColorsOnceOnShow() {
        _ = NSApplication.shared
        let host = TasksHostView(model: TasksModel(source: MockTasksSource()), layout: .fallback)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.displayIfNeeded()

        let shown = host.colorResolves
        window.appearance = NSAppearance(named: .darkAqua)
        window.displayIfNeeded()
        #expect(host.colorResolves == shown + 1, "a shown Tasks pane resolved its colors \(host.colorResolves - shown) times on a theme change (want 1)")

        host.isHidden = true
        let hidden = host.colorResolves
        window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        window.displayIfNeeded()
        window.appearance = NSAppearance(named: .aqua)
        window.displayIfNeeded()
        #expect(host.colorResolves == hidden, "a hidden Tasks pane resolved its colors \(host.colorResolves - hidden) times")

        host.isHidden = false
        window.displayIfNeeded()
        #expect(host.colorResolves == hidden + 1, "the show resolved the hidden theme changes \(host.colorResolves - hidden) times (want 1)")
    }
}
