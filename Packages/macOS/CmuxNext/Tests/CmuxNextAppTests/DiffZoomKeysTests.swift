import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Testing

/// The diff viewer's text size keys (user 2026-11-19: "cmd + and - need to work in diff viewer"): Cmd-= and
/// Cmd-+ (Cmd-Shift-=) make the diff's text bigger, Cmd-- smaller and Cmd-0 the default size while a diff tab
/// has the keyboard, as in the Markdown viewer. A terminal and a browser page keep these keys. Resolved as the
/// key router resolves a key-down, with the app's default bindings, and the page command each action sends.
@MainActor @Suite struct DiffZoomKeysTests {
    static let zoomActions: [ActionID] = ["diffViewerZoomIn", "diffViewerZoomOut", "diffViewerZoomReset"]

    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        for id in zoomActions + ["browserZoomIn", "browserZoomOut", "browserZoomReset", "markdownZoomIn", "markdownZoomOut",
                                 "markdownZoomReset"] {
            registry.bind(id, invoke: { _ in })
        }
        return registry
    }()

    static let diff = KeyContext([KeyContext.surfaceKind: .string("page"), "pageId": .string("cmux.diff"),
                                  "diffViewerFocused": .bool(true)])
    static let terminal = KeyContext([KeyContext.surfaceKind: .string("terminal"), "terminalFocused": .bool(true)])
    static let browser = KeyContext([KeyContext.surfaceKind: .string("page"), "browserFocused": .bool(true)])
    static let markdown = KeyContext([KeyContext.surfaceKind: .string("page"), "markdownFocused": .bool(true)])

    static func winner(_ keys: String, in context: KeyContext) -> String? {
        guard case .object(let report)? = KeybindingReports.resolve(keys, context: context, registry: registry, window: nil),
              report["outcome"]?.stringValue == "run", case .object(let winner)? = report["winner"] else { return nil }
        return winner["command"]?.stringValue
    }

    @Test func theDiffViewerTakesTheSizeKeys() {
        #expect(Self.winner("cmd+equals", in: Self.diff) == "diffViewerZoomIn")
        #expect(Self.winner("cmd+shift+equals", in: Self.diff) == "diffViewerZoomIn")
        #expect(Self.winner("cmd+minus", in: Self.diff) == "diffViewerZoomOut")
        #expect(Self.winner("cmd+0", in: Self.diff) == "diffViewerZoomReset")
    }

    @Test func otherSurfacesKeepThem() {
        for keys in ["cmd+equals", "cmd+shift+equals", "cmd+minus", "cmd+0"] {
            for context in [Self.terminal, Self.browser, Self.markdown] {
                let winner = Self.winner(keys, in: context)
                #expect(winner.map { Self.zoomActions.contains(ActionID(rawValue: $0)) } != true, "\(keys) ran \(winner ?? "")")
            }
        }
        #expect(Self.winner("cmd+equals", in: Self.markdown) == "markdownZoomIn")
    }

    /// Each action sends its zoom command to the diff page, which declares it (the page drops any other).
    @Test func eachActionSendsAZoomCommandTheDiffPageTakes() {
        let sent = Self.zoomActions.map { DiffPageCommand.forAction[$0.rawValue] }
        #expect(sent == ["zoomIn", "zoomOut", "zoomReset"])
        for command in sent.compactMap(\.self) {
            #expect(PageDescriptor.diff.commands.contains(command), "the diff page drops \(command)")
        }
    }
}
