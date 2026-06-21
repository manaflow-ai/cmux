import AppKit
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("MainWindowActivationResolver")
struct MainWindowActivationResolverTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func resolver(
        sortedContextWindows: [NSWindow] = [],
        keyWindow: NSWindow? = nil,
        mainWindow: NSWindow? = nil,
        allWindows: [NSWindow] = [],
        mainTerminalWindows: Set<ObjectIdentifier> = [],
        visibleWindows: Set<ObjectIdentifier> = [],
        miniaturizedWindows: Set<ObjectIdentifier> = []
    ) -> MainWindowActivationResolver {
        MainWindowActivationResolver(
            sortedContextWindows: { sortedContextWindows },
            keyWindow: { keyWindow },
            mainWindow: { mainWindow },
            allWindows: { allWindows },
            isMainTerminalWindow: { mainTerminalWindows.contains(ObjectIdentifier($0)) },
            isVisible: { visibleWindows.contains(ObjectIdentifier($0)) },
            isMiniaturized: { miniaturizedWindows.contains(ObjectIdentifier($0)) }
        )
    }

    @Test("key window wins when it is a main terminal window")
    func keyWindowPreferred() {
        let key = makeWindow()
        let main = makeWindow()
        let r = resolver(
            sortedContextWindows: [makeWindow()],
            keyWindow: key,
            mainWindow: main,
            mainTerminalWindows: [ObjectIdentifier(key), ObjectIdentifier(main)]
        )
        #expect(r.preferredMainWindowForVisibilityActivation() === key)
    }

    @Test("non-terminal key window falls through to main terminal window")
    func mainWindowFallback() {
        let key = makeWindow()
        let main = makeWindow()
        let r = resolver(
            keyWindow: key,
            mainWindow: main,
            mainTerminalWindows: [ObjectIdentifier(main)]
        )
        #expect(r.preferredMainWindowForVisibilityActivation() === main)
    }

    @Test("first visible non-miniaturized context window wins when no key/main terminal")
    func visibleContextWindow() {
        let hidden = makeWindow()
        let mini = makeWindow()
        let visible = makeWindow()
        let r = resolver(
            sortedContextWindows: [hidden, mini, visible],
            visibleWindows: [ObjectIdentifier(mini), ObjectIdentifier(visible)],
            miniaturizedWindows: [ObjectIdentifier(mini)]
        )
        #expect(r.preferredMainWindowForVisibilityActivation() === visible)
    }

    @Test("falls back to first context window when none visible")
    func firstContextFallback() {
        let first = makeWindow()
        let second = makeWindow()
        let r = resolver(sortedContextWindows: [first, second])
        #expect(r.preferredMainWindowForVisibilityActivation() === first)
    }

    @Test("returns nil when there are no candidates")
    func noCandidates() {
        #expect(resolver().preferredMainWindowForVisibilityActivation() == nil)
    }

    @Test("visibility windows union context windows then other main terminal windows, de-duped")
    func visibilityWindowsUnion() {
        let a = makeWindow()
        let b = makeWindow()
        let c = makeWindow()
        let r = resolver(
            sortedContextWindows: [a, b],
            allWindows: [a, c],
            mainTerminalWindows: [ObjectIdentifier(a), ObjectIdentifier(c)]
        )
        let result = r.mainWindowsForVisibilityController()
        #expect(result.count == 3)
        #expect(result[0] === a)
        #expect(result[1] === b)
        #expect(result[2] === c)
    }

    @Test("visibility windows skip non-terminal app windows")
    func visibilityWindowsSkipNonTerminal() {
        let context = makeWindow()
        let other = makeWindow()
        let r = resolver(
            sortedContextWindows: [context],
            allWindows: [context, other],
            mainTerminalWindows: [ObjectIdentifier(context)]
        )
        let result = r.mainWindowsForVisibilityController()
        #expect(result.count == 1)
        #expect(result[0] === context)
    }
}
