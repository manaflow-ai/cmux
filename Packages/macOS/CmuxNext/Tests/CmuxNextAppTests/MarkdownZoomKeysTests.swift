import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The markdown viewer's text size keys (user 2026-10-18): Cmd-= and Cmd-+ (Cmd-Shift-=) make the
/// text bigger, Cmd-- smaller, Cmd-0 the default size, while the viewer has the keyboard. A
/// terminal or a browser page keeps these keys. Resolved as the key router resolves a key-down,
/// with the app's default bindings.
@MainActor @Suite struct MarkdownZoomKeysTests {
    static let zoomActions: [ActionID] = ["markdownZoomIn", "markdownZoomOut", "markdownZoomReset"]

    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        for id in zoomActions + ["browserZoomIn", "browserZoomOut", "browserZoomReset"] {
            registry.bind(id, invoke: { _ in })
        }
        return registry
    }()

    static let markdown = KeyContext([KeyContext.surfaceKind: .string("page"), "markdownFocused": .bool(true)])
    static let terminal = KeyContext([KeyContext.surfaceKind: .string("terminal"), "terminalFocused": .bool(true)])
    static let browser = KeyContext([KeyContext.surfaceKind: .string("page"), "browserFocused": .bool(true)])

    static func winner(_ keys: String, in context: KeyContext) -> String? {
        guard case .object(let report)? = KeybindingReports.resolve(keys, context: context, registry: registry, window: nil),
              report["outcome"]?.stringValue == "run", case .object(let winner)? = report["winner"] else { return nil }
        return winner["command"]?.stringValue
    }

    @Test func theMarkdownViewerTakesTheSizeKeys() {
        #expect(Self.winner("cmd+equals", in: Self.markdown) == "markdownZoomIn")
        #expect(Self.winner("cmd+shift+equals", in: Self.markdown) == "markdownZoomIn")
        #expect(Self.winner("cmd+minus", in: Self.markdown) == "markdownZoomOut")
        #expect(Self.winner("cmd+0", in: Self.markdown) == "markdownZoomReset")
    }

    @Test func aTerminalAndABrowserPageKeepThem() {
        for keys in ["cmd+equals", "cmd+shift+equals", "cmd+minus", "cmd+0"] {
            for context in [Self.terminal, Self.browser] {
                let winner = Self.winner(keys, in: context)
                #expect(winner.map { Self.zoomActions.contains(ActionID(rawValue: $0)) } != true, "\(keys) ran \(winner ?? "")")
            }
        }
        #expect(Self.winner("cmd+equals", in: Self.browser) == "browserZoomIn")
    }
}
