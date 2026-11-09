import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
@testable import MessagesLabSidebar
import Testing

/// Goal a11y-baseline (cmuxterm-hq goals/a11y-baseline.md): VoiceOver meets no control on Home that
/// it can only speak as its role. The probe's first whole read of a fresh Nightly (cmuxterm-hq
/// synthetic-probes run 42599053150, 2026-11-09) found unnamed buttons in the main window, four of
/// them after the Home list's Unread Messages filter. Leo, 2026-11-08: "Every conceivable possible
/// aspect of the app, and also in how we do the app, and just that, like how we work, how we look
/// like to other people, how we can introduce other people to our thing, that kind of thing."
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeAccessibilityNamesTests {
    /// The roles the probe counts as controls (a11y_walk_probe.py CONTROL_ROLES).
    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .popUpButton, .menuButton, .checkBox, .radioButton, .link, .textField, .textArea, .comboBox,
        .slider, .incrementor, .disclosureTriangle, .colorWell,
    ]

    /// One line per control under `root` with no label or title, naming its class and frame.
    static func unnamed(under root: NSView) -> [String] {
        AccessibilityAudit().nodes(under: root).compactMap { node in
            guard controlRoles.contains(node.role), node.label.isEmpty else { return nil }
            let view = (node.element as? NSView) ?? (node.element as? NSCell)?.controlView
            let frame = view.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let help = (node.element as? NSAccessibilityProtocol)?.accessibilityHelp() ?? ""
            return "\(node.path) \(String(describing: type(of: node.element))) id=\(node.identifier) help=\(help) frame=\(frame)"
        }
    }

    /// Home as a fresh window shows it: the list beside the first-run chat with its composer.
    @Test func homeListAndChatNameEveryControl() throws {
        _ = NSApplication.shared
        let suite = "cmux.tests.homeAccessibilityNames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let chat = HomeNativeTranscriptView(store: store, conversation: ConversationID("conv_names"), me: ParticipantID("user_me"))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        let split = HomeSidebarSplitView(sidebar: home, content: chat, widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        split.setWidth(320)
        split.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        let unnamed = Self.unnamed(under: split)
        #expect(unnamed.isEmpty, "\(unnamed.count) unnamed controls on Home:\n\(unnamed.joined(separator: "\n"))")
    }
}
