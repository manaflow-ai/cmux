import Foundation
import Testing

/// Dialogs are native (Lawrence 2026-11-17: "most dialogs should have 0 react involved, except for ones from chat
/// ui/settings ui"): no card, prompt or sheet outside the chat UI and Settings draws a web page. A web page in a
/// floating card (the app health card's empty glass shell) could stay up with nothing drawn and nothing to close it.
///
/// Read from the sources: a file that makes a panel, window, popover or sheet and puts a web page in it, and every
/// card of the floating web card panel (``WebCard``), must be one listed here with its reason.
struct NoWebViewDialogsTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    /// Web content inside a panel, window, popover or sheet that is no dialog, or a dialog of the chat UI or Settings.
    static let allowedWebSurfaces: [String: String] = [
        "CmuxNextAgentPane/AgentPaneView.swift": "the agent chat itself (chat UI)",
        "CmuxNextPages/PageHostPool.swift": "the page host pool: windows that hold page tabs, no dialog",
        "CmuxNextPages/PageHostPool+Windows.swift": "the page host pool's windows, no dialog",
        "CmuxNextOnboarding/Views/OnboardingWindowController.swift": "the onboarding tool window, a window with pages, no dialog",
        "CmuxNextApp/Settings/DebugSettingsService.swift": "Settings UI",
        "CmuxNextSidebar/Views/GroupEditor/GroupEditorService.swift": "the sidebar's group editor, an editor popover, no dialog",
        "CmuxNextApp/IconPicker/IconPickerService.swift": "the icon picker, a picker popover, no dialog",
        "CmuxNextServer/ServerPage/ServerPanelPopover.swift": "the menu bar item's server panel, a status popover, no dialog",
    ]

    /// Cards of a floating web card panel still drawn by a page, each with the work that moves it. Empty: every
    /// card is native (Add Server was the last), and a new card is native too.
    static let webCards: [String: String] = [:]

    static func swiftFiles() throws -> [(path: String, text: String)] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var files: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = String(url.path.dropFirst(sources.path.count + 1))
            files.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    @Test func noDialogOutsideChatAndSettingsHostsAWebPage() throws {
        let page = try Regex(#"PageWebView\(|WebCardPanel\(|PageHostPool"#)
        let surface = try Regex(#": NSPanel\b|: NSWindow\b|NSPanel\(|beginSheet|WindowOverlayHost|CmuxFloatingDialogPanel|OverlayHostPanel|ContentChildPanel|NSPopover"#)
        let files = try Self.swiftFiles()
        #expect(files.count > 500, "read the sources")
        for file in files where file.text.contains(page) && file.text.contains(surface) {
            #expect(Self.allowedWebSurfaces[file.path] != nil,
                    "\(file.path) puts a web page in a panel, window, popover or sheet: draw the dialog natively (CmuxDialogSpec, CmuxFloatingDialogPanel)")
        }
    }

    @Test func everyWebCardIsListed() throws {
        let card = try Regex(#"(?:class|struct)\s+(\w+)\s*:\s*(?:[\w, ]*,\s*)?WebCard\b"#)
        var found: Set<String> = []
        for file in try Self.swiftFiles() {
            for match in file.text.matches(of: card) {
                if let name = match.output[1].substring { found.insert(String(name)) }
            }
        }
        for name in found {
            #expect(Self.webCards[name] != nil, "\(name) is a card drawn by a web page: make it a native dialog card")
        }
    }
}
