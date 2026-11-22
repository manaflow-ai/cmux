import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Page chords a browser's own chrome runs (Chrome, Safari): Back, Forward,
/// Reload, Hard Reload, History, Copy Page URL and Find Previous work while
/// the address bar or the find bar has the keyboard, and Shift-Cmd-G is
/// Find Previous in a browser (in other focus it keeps Group Selected
/// Workspaces).
@MainActor
struct BrowserChromeKeysTests {
    typealias M = KeyOwnershipMatrixTests

    static let ids: [ActionID] = [
        "browserBack", "browserForward", "browserReload", "browserHardReload", "browserShowHistory", "browser.copyURL",
        "browser.findPrevious", "findPrevious", "groupSelectedWorkspaces", "renameTab",
    ]

    static func services() -> AppServices {
        let services = M.services()
        for id in ids { services.registry.bind(id, invoke: { _ in }) }
        return services
    }

    static func key(_ character: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try KeyInterceptionTests.key(character, keyCode: code, flags)
    }

    static var addressBar: M.Surface { M.Surface(name: "address bar", focus: M.focused(.browser, tab: "b1", target: .addressBar)) }
    static var findBar: M.Surface { M.Surface(name: "find bar", focus: M.focused(.browser, tab: "b1", target: .findBar)) }

    @Test func pageChordsRunFromTheAddressBarAndTheFindBar() throws {
        let services = Self.services()
        let chords: [(NSEvent, ActionID)] = [
            (try Self.key("[", 33, [.command]), "browserBack"),
            (try Self.key("]", 30, [.command]), "browserForward"),
            (try Self.key("r", 15, [.command]), "browserReload"),
            (try Self.key("r", 15, [.command, .shift]), "browserHardReload"),
            (try Self.key("y", 16, [.command]), "browserShowHistory"),
            (try Self.key("c", 8, [.command, .shift]), "browser.copyURL"),
        ]
        for surface in [Self.addressBar, Self.findBar] {
            for (event, id) in chords {
                #expect(M.owner(services, event, surface) == .action(id), "\(surface.name) \(id)")
            }
        }
        // Editing chords stay the field's.
        #expect(M.owner(services, try Self.key("a", 0, [.command]), Self.addressBar) == .surface)
    }

    @Test func shiftCommandGIsFindPreviousInABrowser() throws {
        let services = Self.services()
        let shiftG = try Self.key("g", 5, [.command, .shift])
        #expect(M.owner(services, shiftG, M.Surface(name: "page", focus: M.page)) == .action("browser.findPrevious"))
        #expect(M.owner(services, shiftG, Self.findBar) == .action("browser.findPrevious"))
        // A focused terminal gives it to Ghostty (its previous match), as in Ghostty and the
        // shipping cmux (`KeyBindingDefaults.yieldsToTerminal`, f28642f0be43).
        #expect(M.owner(services, shiftG, M.Surface(name: "terminal", focus: M.terminal)) == .surface)
    }
}
