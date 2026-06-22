import AppKit
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("OrderedMainWindowResolver")
struct OrderedMainWindowResolverTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func resolver(
        keyWindow: NSWindow? = nil,
        mainWindow: NSWindow? = nil,
        orderedWindows: [NSWindow] = []
    ) -> OrderedMainWindowResolver {
        OrderedMainWindowResolver(
            keyWindow: { keyWindow },
            mainWindow: { mainWindow },
            orderedWindows: { orderedWindows }
        )
    }

    @Test("key window projection wins when it projects")
    func keyWindowWins() {
        let key = makeWindow()
        let main = makeWindow()
        let r = resolver(keyWindow: key, mainWindow: main, orderedWindows: [main, key])
        let projectable: Set<ObjectIdentifier> = [ObjectIdentifier(key), ObjectIdentifier(main)]
        let result = r.resolve(
            project: { projectable.contains(ObjectIdentifier($0)) ? ObjectIdentifier($0) : nil },
            fallback: { nil }
        )
        #expect(result == ObjectIdentifier(key))
    }

    @Test("main window wins when key window does not project")
    func mainWindowWinsWhenKeyDoesNotProject() {
        let key = makeWindow()
        let main = makeWindow()
        let r = resolver(keyWindow: key, mainWindow: main, orderedWindows: [])
        let result = r.resolve(
            project: { $0 === main ? ObjectIdentifier($0) : nil },
            fallback: { nil }
        )
        #expect(result == ObjectIdentifier(main))
    }

    @Test("ordered windows are tried after key and main, first projection wins")
    func orderedWindowsTriedInOrder() {
        let a = makeWindow()
        let b = makeWindow()
        let r = resolver(keyWindow: nil, mainWindow: nil, orderedWindows: [a, b])
        let projectable: Set<ObjectIdentifier> = [ObjectIdentifier(a), ObjectIdentifier(b)]
        let result = r.resolve(
            project: { projectable.contains(ObjectIdentifier($0)) ? ObjectIdentifier($0) : nil },
            fallback: { nil }
        )
        #expect(result == ObjectIdentifier(a))
    }

    @Test("a window is projected at most once even if it repeats across sources")
    func dedupAcrossSources() {
        let shared = makeWindow()
        var projectCalls = 0
        let r = resolver(keyWindow: shared, mainWindow: shared, orderedWindows: [shared])
        let result: ObjectIdentifier? = r.resolve(
            project: { window in
                projectCalls += 1
                return window === shared ? nil : ObjectIdentifier(window)
            },
            fallback: { nil }
        )
        #expect(result == nil)
        #expect(projectCalls == 1)
    }

    @Test("fallback is used when no ordered window projects")
    func fallbackUsedWhenNothingProjects() {
        let a = makeWindow()
        let fallback = makeWindow()
        let r = resolver(keyWindow: nil, mainWindow: nil, orderedWindows: [a])
        let result = r.resolve(
            project: { _ in nil as ObjectIdentifier? },
            fallback: { ObjectIdentifier(fallback) }
        )
        #expect(result == ObjectIdentifier(fallback))
    }
}
