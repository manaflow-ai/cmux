import AppKit
import Foundation
import Testing
@testable import CmuxConversationCore
@testable import CmuxConversationMacUI

/// Messages' menu bar (File, Edit > Search, View, Conversation, Format):
/// each command's shortcut and its menu item run one action. These live in
/// the keyboard suite so its `.serialized` trait also covers the app-wide
/// text size they change.
extension MacKeyboardSelectionTests {
    private static let codes: [String: UInt16] = [
        "n": 45, "g": 5, "=": 24, "-": 27, "0": 29, "u": 32, "i": 34, "b": 11, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28,
    ]

    private static func command(_ spec: String) -> MacConversationCommand? {
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for token in spec.split(separator: "+").map(String.init) {
            switch token {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: key = token
            }
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                           characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: codes[key] ?? 0) else { return nil }
        return MacConversationCommands.command(matching: event)
    }

    @Test func menuBarShortcutsMatchMessages() {
        typealias Split = MacConversationSplitController
        typealias Controller = MacConversationViewController
        #expect(Self.command("cmd+n")?.action == #selector(Split.newMessage(_:)))
        #expect(Self.command("cmd+g")?.action == #selector(Split.findNextMatch(_:)))
        #expect(Self.command("cmd+shift+g")?.action == #selector(Split.findPreviousMatch(_:)))
        // ⌘+ answers on the =/+ key with or without Shift.
        #expect(Self.command("cmd+=")?.action == #selector(Split.makeTextBigger(_:)))
        #expect(Self.command("cmd+shift+=")?.action == #selector(Split.makeTextBigger(_:)))
        #expect(Self.command("cmd+-")?.action == #selector(Split.makeTextSmaller(_:)))
        #expect(Self.command("cmd+option+0")?.action == #selector(Split.makeTextNormalSize(_:)))
        #expect(Self.command("cmd+ctrl+u")?.action == #selector(Split.filterUnread(_:)))
        #expect(Self.command("cmd+option+i")?.action == NSSelectorFromString("toggleConversationDetails:"))
        #expect(Self.command("cmd+option+b")?.action == #selector(Split.showContactCard(_:)))
        #expect(Self.command("cmd+shift+u")?.action == #selector(Split.markConversationUnread(_:)))
        #expect(Self.command("cmd+option+shift+u")?.action == #selector(Split.markAllConversationsRead(_:)))
        #expect(Self.command("cmd+option+m")?.action == #selector(Split.toggleConversationAlerts(_:)))
        #expect(Self.command("cmd+b")?.action == #selector(Controller.toggleTextStyle(_:)))
        #expect(Self.command("cmd+b")?.tag == ConversationTextStyle.bold.rawValue)
        #expect(Self.command("cmd+u")?.tag == ConversationTextStyle.underline.rawValue)
        for (index, effect) in ConversationTextEffect.allCases.enumerated() {
            let command = Self.command("cmd+option+\(index + 1)")
            #expect(command?.action == #selector(Controller.applyTextEffect(_:)), "\(effect)")
            #expect(command?.tag == index, "\(effect)")
        }
        // No two shortcuts collide.
        let combos = MacConversationCommands.keyed.map { "\($0.key)|\($0.modifiers.rawValue)" }
        #expect(Set(combos).count == combos.count)
    }

    @Test func labMenuBarListsTheConversationAndFormatMenus() throws {
        _ = NSApplication.shared
        let bar = MacConversationLab.makeMainMenu(appName: "Lab")
        func menu(_ title: String) throws -> NSMenu { try #require(bar.items.first { $0.title == title }?.submenu, "\(bar.items.map(\.title))") }
        let conversation = try menu("Conversation")
        #expect(conversation.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Show Details", "Show Contact Card", "-", "Mark as Unread", "Mark All as Read", "Hide Alerts", "-", "Delete Conversation…",
        ])
        let format = try menu("Format")
        let effects = format.items.filter { $0.action == #selector(MacConversationViewController.applyTextEffect(_:)) }
        #expect(effects.map(\.title) == ["Big", "Small", "Shake", "Nod", "Explode", "Ripple", "Bloom", "Jitter"])
        #expect(effects.map(\.keyEquivalent) == (1...8).map(String.init))
        #expect(effects.allSatisfy { $0.keyEquivalentModifierMask == [.command, .option] })
        let view = try menu("View")
        #expect(view.items.contains { $0.title == "Make Text Bigger" && $0.keyEquivalent == "+" })
        #expect(view.items.contains { $0.title == "Unread" && $0.keyEquivalent == "u" && $0.keyEquivalentModifierMask == [.command, .control] })
        let search = try #require(try menu("Edit").items.first { $0.title == "Search" }?.submenu)
        #expect(search.items.map(\.title) == ["Find…", "Find Next", "Find Previous"])
        #expect(try menu("File").items.map(\.title).prefix(2) == ["New Message", "Open Conversation in New Window"])
    }

    @Test func newMenuShortcutsReachTheConversationWindowAheadOfTheHost() async throws {
        let lab = try await Lab()
        func event(_ spec: String) throws -> NSEvent {
            let parts = spec.split(separator: "+").map(String.init)
            var flags: NSEvent.ModifierFlags = [.command]
            if parts.contains("option") { flags.insert(.option) }
            if parts.contains("shift") { flags.insert(.shift) }
            let key = parts.last ?? ""
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: lab.window.windowNumber,
                                                 context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: Self.codes[key] ?? 0))
        }
        // The AppDelegate DEBUG guard asks this before cmux's shortcut monitor.
        #expect(MacConversationLab.handlesShortcut(try event("cmd+n"), in: lab.window))
        #expect(MacConversationLab.handlesShortcut(try event("cmd+="), in: lab.window))
        #expect(MacConversationLab.handlesShortcut(try event("cmd+option+i"), in: lab.window))
        #expect(MacConversationLab.handlesShortcut(try event("cmd+option+8"), in: lab.window))
        // Show Details has no answer until the details panel lands: the key
        // is still the conversation's (consumed), never the host's.
        #expect(MacConversationCommands.target(for: MacConversationCommands.showDetails.action, in: lab.window) == nil)
        #expect(lab.key("cmd+option+i") == "keyEquivalent")
    }

    @Test func textSizeCommandsScaleTheTranscriptAndPersist() async throws {
        let suite = "cmux.conversation.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let saved = MacConversationTextSize.defaults
        MacConversationTextSize.defaults = defaults
        defer {
            MacConversationTextSize.set(MacConversationTextSize.defaultSize)
            MacConversationTextSize.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        MacConversationTextSize.set(MacConversationTextSize.defaultSize)
        let lab = try await Lab()
        lab.focusComposer()
        let index = try #require(lab.controller.rows.indices.last { lab.controller.messageModel(at: $0) != nil })
        let model = try #require(lab.controller.messageModel(at: index))
        let before = try #require(lab.controller.layoutCache.layout(model, width: lab.controller.transcriptWidth).bubbleFrame)
        #expect(before.height == 32)
        #expect(!lab.split.canPerform(#selector(MacConversationSplitController.makeTextNormalSize(_:))))

        #expect(lab.key("cmd+=") == "keyEquivalent")
        #expect(MacConversationTextSize.current == 14)
        #expect(defaults.double(forKey: MacConversationTextSize.defaultsKey) == 14)
        let after = try #require(lab.controller.layoutCache.layout(model, width: lab.controller.transcriptWidth).bubbleFrame)
        #expect(after.height > before.height)
        // The on-screen bubble re-laid out at the new size.
        lab.split.view.layoutSubtreeIfNeeded()
        let row = try #require(lab.controller.rowView(at: index))
        let font = row.textLabel.attributedText.attribute(NSAttributedString.Key.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 14)
        // The composer keeps Messages' default size.
        #expect(lab.controller.composer.textView.font?.pointSize == 13)

        lab.key("cmd+-")
        lab.key("cmd+-")
        #expect(MacConversationTextSize.current == 12)
        lab.key("cmd+option+0")
        #expect(MacConversationTextSize.current == 13)
        #expect(defaults.object(forKey: MacConversationTextSize.defaultsKey) == nil)
        let restored = try #require(lab.controller.layoutCache.layout(model, width: lab.controller.transcriptWidth).bubbleFrame)
        #expect(restored.height == before.height)
    }

    @Test func conversationMenuRunsTheSidebarActions() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let id = try #require(lab.split.selected?.id)
        func state() throws -> (state: ConversationListState, isUnread: Bool) { try #require(lab.split.sidebar.entryState(id)) }
        let markUnread = NSMenuItem(title: "", action: #selector(MacConversationSplitController.markConversationUnread(_:)), keyEquivalent: "")

        // Mark as Unread (⇧⌘U), then the menu item reads Mark as Read.
        if try state().isUnread { lab.split.sidebar.perform(.toggleUnread, on: try #require(lab.split.selected)) }
        try await waitUntil { (try? state().isUnread) == false }
        #expect(lab.key("cmd+shift+u") == "keyEquivalent")
        #expect(try state().state.markedUnread)
        #expect(lab.split.validateMenuItem(markUnread))
        #expect(markUnread.title == "Mark as Read")

        // Mark All as Read (⌥⇧⌘U) clears every conversation.
        lab.key("cmd+option+shift+u")
        try await waitUntil { lab.split.entries.allSatisfy { lab.split.sidebar.entryState($0.id)?.isUnread == false } }
        #expect(!lab.split.canPerform(#selector(MacConversationSplitController.markAllConversationsRead(_:))))

        // Hide Alerts (⌥⌘M) is a checkmark toggle.
        lab.key("cmd+option+m")
        #expect(try state().state.muted)
        let alerts = NSMenuItem(title: "", action: #selector(MacConversationSplitController.toggleConversationAlerts(_:)), keyEquivalent: "")
        _ = lab.split.validateMenuItem(alerts)
        #expect(alerts.state == .on)
        lab.key("cmd+option+m")
        #expect(try !state().state.muted)

        // Delete Conversation… runs the sidebar's delete (which asks first).
        #expect(MacConversationCommands.target(for: MacConversationCommands.deleteConversation.action, in: lab.window) === lab.split)
        #expect(lab.split.canPerform(MacConversationCommands.deleteConversation.action))
    }

    @Test func contactCardOpensForOnePersonOnly() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        #expect(lab.split.selected?.id == "direct")
        lab.key("cmd+option+b")
        #expect(lab.split.contactCard?.contentViewController is MacMentionCardController)
        lab.split.select(try #require(lab.split.entries.first { $0.id == "group" }))
        #expect(!lab.split.canPerform(#selector(MacConversationSplitController.showContactCard(_:))))
    }

    @Test func filterByUnreadDraftsAndSendLater() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let sidebar = lab.split.sidebar
        let selected = try #require(lab.split.selected?.id)
        let other = try #require(lab.split.entries.first { $0.id != selected })
        // The other conversation reads, so Unread lists only the open one.
        if sidebar.entryState(other.id)?.isUnread == true { sidebar.perform(.toggleUnread, on: other) }
        try await waitUntil { sidebar.entryState(other.id)?.isUnread == false }

        lab.key("cmd+ctrl+u")
        #expect(sidebar.filter == .unread)
        #expect(sidebar.visibleIDs == [selected])
        sidebar.perform(.toggleUnread, on: other)
        #expect(Set(sidebar.visibleIDs) == [selected, other.id])
        lab.key("cmd+ctrl+u")
        #expect(sidebar.filter == .all)
        #expect(Set(sidebar.visibleIDs) == [selected, other.id])

        // Drafts: a conversation with unsent text.
        lab.split.filterDrafts(nil)
        #expect(sidebar.visibleIDs == [selected])
        other.controller.composer.text = "half a thought"
        lab.split.filterDrafts(nil)
        lab.split.filterDrafts(nil)
        #expect(Set(sidebar.visibleIDs) == [selected, other.id])

        // Send Later lists nothing until scheduled messages exist (feat-imsg-send-later).
        lab.split.filterSendLater(nil)
        #expect(sidebar.filter == .sendLater)
        #expect(sidebar.visibleIDs == [selected])
        lab.split.filterSendLater(nil)
        #expect(sidebar.filter == .all)
    }

    @Test func findNextAndPreviousCycleTranscriptMatches() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        #expect(!lab.split.canPerform(#selector(MacConversationSplitController.findNextMatch(_:))))
        lab.split.sidebar.setSearch("the")
        func highlighted() -> String? {
            guard let match = lab.controller.keyboard.findMatch,
                  let index = lab.controller.rows.firstIndex(where: { $0.id == match.rowID }),
                  let row = lab.controller.rowView(at: index), row.textLabel.findHighlightRange == match.range else { return nil }
            return (row.textLabel.string as NSString).substring(with: match.range) + " @ " + (row.model?.message.id ?? "")
        }
        // "the" appears in m1, m4 and m5; the first Find Next lands on the newest.
        #expect(lab.key("cmd+g") == "keyEquivalent")
        #expect(highlighted() == "the @ m5")
        lab.key("cmd+g")
        #expect(highlighted() == "the @ m1")
        lab.key("cmd+g")
        #expect(highlighted() == "the @ m4")
        lab.key("cmd+shift+g")
        #expect(highlighted() == "the @ m1")
        lab.key("cmd+shift+g")
        #expect(highlighted() == "the @ m5")
        // A new search drops the highlight.
        lab.split.sidebar.setSearch("standup")
        #expect(lab.controller.keyboard.findMatch == nil)
        lab.key("cmd+g")
        #expect(highlighted() == "standup @ m4")
        lab.split.sidebar.setSearch("no such words")
        lab.key("cmd+g")
        #expect(lab.controller.keyboard.findMatch == nil)
    }

    @Test func textEffectShortcutsApplyToTheComposerSelection() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let textView = lab.controller.composer.textView
        lab.controller.composer.text = "hello there"
        textView.setSelectedRange(NSRange(location: 6, length: 5))
        #expect(lab.key("cmd+option+1") == "keyEquivalent")
        #expect(textView.activeEffect == .big)
        lab.key("cmd+option+8")
        #expect(textView.activeEffect == .jitter)
        #expect(lab.controller.composer.textRuns.contains { $0.effect == .jitter && $0.location == 6 && $0.length == 5 })
        lab.key("cmd+b")
        #expect(textView.activeStyle.contains(.bold))
        // The Format items show the composer's state.
        let jitter = NSMenuItem(title: "", action: #selector(MacConversationViewController.applyTextEffect(_:)), keyEquivalent: "")
        jitter.tag = ConversationTextEffect.allCases.firstIndex(of: .jitter)!
        #expect(lab.controller.validateMenuItem(jitter))
        #expect(jitter.state == .on)
        // Outside the message field the Format commands are off.
        lab.key("shift+tab")
        #expect(!lab.controller.validateMenuItem(jitter))
    }

    @Test func openConversationInNewWindowAndNewMessageSeam() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let before = MacConversationLab.conversationWindows.count
        lab.split.openConversationInNewWindow(nil)
        #expect(MacConversationLab.conversationWindows.count == before + 1)
        let window = try #require(MacConversationLab.conversationWindows.last)
        let split = try #require(window.contentViewController as? MacConversationSplitController)
        #expect(split.entries.map(\.id) == ["direct"])
        #expect(split.entries[0].store !== lab.controller.store)
        #expect(split.splitViewItems.first?.isCollapsed == true)
        window.close()
        #expect(MacConversationLab.conversationWindows.count == before)

        // New Message is off until the compose flow installs its handler.
        #expect(!lab.split.canPerform(#selector(MacConversationSplitController.newMessage(_:))))
        var opened = 0
        MacConversationLab.composeHandler = { _ in opened += 1 }
        defer { MacConversationLab.composeHandler = nil }
        #expect(lab.key("cmd+n") == "keyEquivalent")
        #expect(opened == 1)
    }
}
