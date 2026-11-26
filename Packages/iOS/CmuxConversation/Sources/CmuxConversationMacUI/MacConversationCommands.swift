#if os(macOS)
import AppKit
import CmuxConversationCore

/// One Messages command: a responder-chain action with Messages' key
/// equivalent. The lab's menu bar and the conversation window's own key
/// handling both come from this table, so a shortcut and its menu item
/// always run the same action.
@MainActor
struct MacConversationCommand {
    let action: Selector
    /// The menu key equivalent ("\t" Tab, "\r" Return).
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let title: () -> String
    /// Picks the variant for actions shared by a family (text styles, effects).
    var tag = 0
}

/// Responders that can refuse a command (a disabled menu item, a beep).
@MainActor
protocol MacConversationCommandValidating: AnyObject {
    func canPerform(_ action: Selector) -> Bool
    /// Family commands (text styles, effects) validate per tag.
    func canPerform(_ action: Selector, tag: Int) -> Bool
}

extension MacConversationCommandValidating {
    func canPerform(_ action: Selector, tag: Int) -> Bool { canPerform(action) }
}

@MainActor
enum MacConversationCommands {
    // Measured against macOS 26 Messages' menu bar (AX dump of Messages.app):
    // Edit > Send Message ⌘↩, Reply to Message… ⌘R, Continue Last Reply… ⇧⌘R,
    // Tapback Message… ⌘T, Edit Last Message… ⌘E, Edit > Search > Find… ⌘F,
    // Window > Go to Next / Previous Conversation ⌃⇥ / ⌃⇧⇥.
    static let send = MacConversationCommand(
        action: #selector(MacConversationViewController.sendMessage(_:)), key: "\r", modifiers: .command,
        title: { String(localized: "conversation.command.send", defaultValue: "Send Message", bundle: .module) }
    )
    static let reply = MacConversationCommand(
        action: #selector(MacConversationViewController.replyToMessage(_:)), key: "r", modifiers: .command,
        title: { String(localized: "conversation.command.reply", defaultValue: "Reply to Message…", bundle: .module) }
    )
    static let continueReply = MacConversationCommand(
        action: #selector(MacConversationViewController.continueLastReply(_:)), key: "r", modifiers: [.command, .shift],
        title: { String(localized: "conversation.command.continueReply", defaultValue: "Continue Last Reply…", bundle: .module) }
    )
    static let tapback = MacConversationCommand(
        action: #selector(MacConversationViewController.tapbackMessage(_:)), key: "t", modifiers: .command,
        title: { String(localized: "conversation.command.tapback", defaultValue: "Tapback Message…", bundle: .module) }
    )
    static let editLast = MacConversationCommand(
        action: #selector(MacConversationViewController.editLastMessage(_:)), key: "e", modifiers: .command,
        title: { String(localized: "conversation.command.editLast", defaultValue: "Edit Last Message…", bundle: .module) }
    )
    static let find = MacConversationCommand(
        action: #selector(MacConversationSplitController.searchConversations(_:)), key: "f", modifiers: .command,
        title: { String(localized: "conversation.command.find", defaultValue: "Find…", bundle: .module) }
    )
    static let nextConversation = MacConversationCommand(
        action: #selector(MacConversationSplitController.selectNextConversation(_:)), key: "\t", modifiers: .control,
        title: { String(localized: "conversation.command.nextConversation", defaultValue: "Go to Next Conversation", bundle: .module) }
    )
    static let previousConversation = MacConversationCommand(
        action: #selector(MacConversationSplitController.selectPreviousConversation(_:)), key: "\t", modifiers: [.control, .shift],
        title: { String(localized: "conversation.command.previousConversation", defaultValue: "Go to Previous Conversation", bundle: .module) }
    )
    static let showTimes = MacConversationCommand(
        action: #selector(MacConversationViewController.toggleShowTimes(_:)), key: "", modifiers: [],
        title: { String(localized: "conversation.command.showTimes", defaultValue: "Show Times", bundle: .module) }
    )
    /// Edit Background (ChatKit EDIT_BACKGROUND); the same picker as the
    /// transcript's context menu and the details panel.
    static let editBackground = MacConversationCommand(
        action: #selector(MacConversationViewController.editBackground(_:)), key: "", modifiers: [],
        title: { String(localized: "conversation.command.editBackground", defaultValue: "Edit Background…", bundle: .module) }
    )


    // File, Edit > Search, View, Conversation and Format, from the same AX dump.
    // Titles are ChatKit's own strings (keys in comments).

    /// File > New Message (⌘N). NEW_MESSAGE
    static let newMessage = MacConversationCommand(
        action: #selector(MacConversationSplitController.newMessage(_:)), key: "n", modifiers: .command,
        title: { String(localized: "conversation.command.newMessage", defaultValue: "New Message", bundle: .module) }
    )
    /// File > Open Conversation in New Window. OPEN_CONVERSATION_IN_NEW_WINDOW
    static let openInNewWindow = MacConversationCommand(
        action: #selector(MacConversationSplitController.openConversationInNewWindow(_:)), key: "", modifiers: [],
        title: { String(localized: "conversation.command.openInNewWindow", defaultValue: "Open Conversation in New Window", bundle: .module) }
    )
    /// Edit > Search > Find Next (⌘G). FIND_NEXT
    static let findNext = MacConversationCommand(
        action: #selector(MacConversationSplitController.findNextMatch(_:)), key: "g", modifiers: .command,
        title: { String(localized: "conversation.command.findNext", defaultValue: "Find Next", bundle: .module) }
    )
    /// Edit > Search > Find Previous (⇧⌘G). FIND_PREVIOUS
    static let findPrevious = MacConversationCommand(
        action: #selector(MacConversationSplitController.findPreviousMatch(_:)), key: "g", modifiers: [.command, .shift],
        title: { String(localized: "conversation.command.findPrevious", defaultValue: "Find Previous", bundle: .module) }
    )
    /// View > Make Text Bigger (⌘+). MAKE_TEXT_BIGGER
    static let textBigger = MacConversationCommand(
        action: #selector(MacConversationSplitController.makeTextBigger(_:)), key: "+", modifiers: .command,
        title: { String(localized: "conversation.command.textBigger", defaultValue: "Make Text Bigger", bundle: .module) }
    )
    /// View > Make Text Normal Size (⌥⌘0). MAKE_TEXT_NORMAL_SIZE
    static let textNormal = MacConversationCommand(
        action: #selector(MacConversationSplitController.makeTextNormalSize(_:)), key: "0", modifiers: [.command, .option],
        title: { String(localized: "conversation.command.textNormal", defaultValue: "Make Text Normal Size", bundle: .module) }
    )
    /// View > Make Text Smaller (⌘-). MAKE_TEXT_SMALLER
    static let textSmaller = MacConversationCommand(
        action: #selector(MacConversationSplitController.makeTextSmaller(_:)), key: "-", modifiers: .command,
        title: { String(localized: "conversation.command.textSmaller", defaultValue: "Make Text Smaller", bundle: .module) }
    )
    /// View > Filter By > Unread (⌃⌘U). UNREAD
    static let filterUnread = MacConversationCommand(
        action: #selector(MacConversationSplitController.filterUnread(_:)), key: "u", modifiers: [.command, .control],
        title: { String(localized: "conversation.command.filterUnread", defaultValue: "Unread", bundle: .module) }
    )
    /// View > Filter By > Drafts. DRAFTS
    static let filterDrafts = MacConversationCommand(
        action: #selector(MacConversationSplitController.filterDrafts(_:)), key: "", modifiers: [],
        title: { String(localized: "conversation.command.filterDrafts", defaultValue: "Drafts", bundle: .module) }
    )
    /// View > Filter By > Send Later. SEND_LATER_TRANSCRIPT
    static let filterSendLater = MacConversationCommand(
        action: #selector(MacConversationSplitController.filterSendLater(_:)), key: "", modifiers: [],
        title: { String(localized: "conversation.command.filterSendLater", defaultValue: "Send Later", bundle: .module) }
    )
    /// Conversation > Show Details (⌥⌘I). SHOW_DETAILS / HIDE_DETAILS_VIEW.
    /// The details panel implements `toggleConversationDetails(_:)` on the
    /// conversation controller; until then nothing answers and the item is off.
    static let showDetails = MacConversationCommand(
        action: NSSelectorFromString("toggleConversationDetails:"), key: "i", modifiers: [.command, .option],
        title: { String(localized: "conversation.command.showDetails", defaultValue: "Show Details", bundle: .module) }
    )
    /// Conversation > Show Contact Card (⌥⌘B). SHOW_CONTACT_CARD
    static let showContactCard = MacConversationCommand(
        action: #selector(MacConversationSplitController.showContactCard(_:)), key: "b", modifiers: [.command, .option],
        title: { String(localized: "conversation.command.showContactCard", defaultValue: "Show Contact Card", bundle: .module) }
    )
    /// Conversation > Mark as Unread / Mark as Read (⇧⌘U). MARK_AS_UNREAD / MARK_AS_READ
    static let markUnread = MacConversationCommand(
        action: #selector(MacConversationSplitController.markConversationUnread(_:)), key: "u", modifiers: [.command, .shift],
        title: { MacListStrings.markUnread }
    )
    /// Conversation > Mark All as Read (⌥⇧⌘U). MARK_ALL_AS_READ
    static let markAllRead = MacConversationCommand(
        action: #selector(MacConversationSplitController.markAllConversationsRead(_:)), key: "u", modifiers: [.command, .option, .shift],
        title: { String(localized: "conversation.command.markAllRead", defaultValue: "Mark All as Read", bundle: .module) }
    )
    /// Conversation > Hide Alerts (⌥⌘M), a checkmark toggle. MENU_BAR_HIDE_ALERTS_TOGGLE_TITLE
    static let hideAlerts = MacConversationCommand(
        action: #selector(MacConversationSplitController.toggleConversationAlerts(_:)), key: "m", modifiers: [.command, .option],
        title: { MacListStrings.hideAlerts }
    )
    /// Conversation > Delete Conversation…. DELETE_CONVERSATION_ELLIPSIS
    static let deleteConversation = MacConversationCommand(
        action: #selector(MacConversationSplitController.deleteConversation(_:)), key: "", modifiers: [],
        title: { MacListStrings.deleteConversation }
    )
    /// Format > Bold ⌘B, Italic ⌘I, Underline ⌘U, Strikethrough.
    static let textStyles: [MacConversationCommand] = ConversationTextStyle.all.map { entry in
        let key: String
        switch entry.style {
        case .bold: key = "b"
        case .italic: key = "i"
        case .underline: key = "u"
        default: key = ""
        }
        return MacConversationCommand(
            action: #selector(MacConversationViewController.toggleTextStyle(_:)), key: key, modifiers: key.isEmpty ? [] : .command,
            title: { MacComposerTextView.styleName(entry.style) }, tag: entry.style.rawValue
        )
    }
    /// Format > Text Effects: Big ⌥⌘1 … Jitter ⌥⌘8, in ChatKit's order.
    static let textEffects: [MacConversationCommand] = ConversationTextEffect.allCases.enumerated().map { index, effect in
        MacConversationCommand(
            action: #selector(MacConversationViewController.applyTextEffect(_:)), key: "\(index + 1)", modifiers: [.command, .option],
            title: { MacComposerTextView.effectName(effect) }, tag: index
        )
    }

    /// Every command in the table.
    static let all: [MacConversationCommand] = [
        send, reply, continueReply, tapback, editLast, find, nextConversation, previousConversation, showTimes,
        newMessage, openInNewWindow, findNext, findPrevious, textBigger, textNormal, textSmaller,
        filterUnread, filterDrafts, filterSendLater, showDetails, showContactCard, markUnread, markAllRead, hideAlerts, deleteConversation,
    ] + textStyles + textEffects

    /// Commands the conversation window answers itself, ahead of any host
    /// app's menus or shortcut monitors: every command with a shortcut.
    static let keyed: [MacConversationCommand] = all.filter { !$0.key.isEmpty }

    static func command(matching event: NSEvent) -> MacConversationCommand? {
        guard event.type == .keyDown else { return nil }
        var flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key: String
        switch event.keyCode {
        case 48: key = "\t"
        case 36, 76: key = "\r"
        // ⌘+ and ⌘- answer on the =/+ and -/_ keys with or without Shift
        // (and on the keypad), as Messages' text size items do.
        case 24, 69:
            key = "+"
            flags.remove(.shift)
        case 27, 78:
            key = "-"
            flags.remove(.shift)
        default: key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        return keyed.first { $0.key == key && $0.modifiers == flags }
    }

    /// The first responder up the window's chain that implements `action`.
    /// Walks from the first responder like NSApp does, but works whether or
    /// not the window is key (driven lab runs never activate).
    static func target(for action: Selector, in window: NSWindow) -> NSResponder? {
        func resolve(_ responder: NSResponder) -> NSResponder? {
            if responder.responds(to: action) { return responder }
            return responder.supplementalTarget(forAction: action, sender: window) as? NSResponder
        }
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if let target = resolve(current) { return target }
            responder = current.nextResponder
        }
        return window.contentViewController.flatMap(resolve)
    }

    /// Runs `command` like its menu item: a refused command beeps, as a
    /// disabled Messages menu item's key equivalent does.
    @discardableResult
    static func perform(_ command: MacConversationCommand, in window: NSWindow) -> Bool {
        guard let target = target(for: command.action, in: window) else { return false }
        if let validating = target as? any MacConversationCommandValidating, !validating.canPerform(command.action, tag: command.tag) {
            NSSound.beep()
            return true
        }
        // The sender carries the tag, as the command's menu item would.
        let sender = NSMenuItem(title: command.title(), action: command.action, keyEquivalent: "")
        sender.tag = command.tag
        return NSApp.sendAction(command.action, to: target, from: sender)
    }
}

/// The conversation window: Messages' shortcuts reach the conversation
/// before the host app's menus.
final class MacConversationWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let command = MacConversationCommands.command(matching: event) {
            // A Messages shortcut nothing here answers yet (a disabled item)
            // beeps rather than reaching the host app's menus.
            if !MacConversationCommands.perform(command, in: self) { NSSound.beep() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension MacConversationLab {
    /// Whether `event` is a Messages shortcut for a conversation window,
    /// which the window performs itself; a host app's shortcut monitor
    /// should let it through untouched.
    public static func handlesShortcut(_ event: NSEvent, in window: NSWindow? = nil) -> Bool {
        guard (window ?? event.window ?? NSApp.keyWindow) is MacConversationWindow else { return false }
        return MacConversationCommands.command(matching: event) != nil
    }

    /// A Messages-shaped menu bar for the standalone lab runner (the cmux
    /// host keeps its own menus; the window still answers the shortcuts).
    public static func makeMainMenu(appName: String = ProcessInfo.processInfo.processName) -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func item(_ command: MacConversationCommand) -> NSMenuItem {
            let entry = item(command.title(), command.action, command.key, command.modifiers)
            entry.tag = command.tag
            return entry
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            parent.submenu = menu
            return parent
        }
        // Every lookup carries its English default: SwiftPM builds (the lab
        // runner, tests) ship the string catalog uncompiled.
        let l = { (key: StaticString, english: String.LocalizationValue) in String(localized: key, defaultValue: english, bundle: .module) }
        let bar = NSMenu()

        let services = NSMenu(title: l("conversation.menu.services", "Services"))
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: l("conversation.menu.services", "Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        bar.addItem(submenu(appName, [
            item(String(format: l("conversation.menu.about", "About %@"), appName), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            servicesItem,
            .separator(),
            item(String(format: l("conversation.menu.hide", "Hide %@"), appName), #selector(NSApplication.hide(_:)), "h"),
            item(l("conversation.menu.hideOthers", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(l("conversation.menu.showAll", "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(format: l("conversation.menu.quit", "Quit %@"), appName), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        bar.addItem(submenu(l("conversation.menu.file", "File"), [
            item(MacConversationCommands.newMessage),
            item(MacConversationCommands.openInNewWindow),
            item(l("conversation.menu.close", "Close"), #selector(NSWindow.performClose(_:)), "w"),
        ]))
        bar.addItem(submenu(l("conversation.menu.editMenu", "Edit"), [
            item(l("conversation.menu.undo", "Undo"), Selector(("undo:")), "z"),
            item(l("conversation.menu.redo", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(l("conversation.menu.cut", "Cut"), #selector(NSText.cut(_:)), "x"),
            item(l("conversation.menu.copy", "Copy"), #selector(NSText.copy(_:)), "c"),
            item(l("conversation.menu.paste", "Paste"), #selector(NSText.paste(_:)), "v"),
            item(l("conversation.menu.pasteAndMatchStyle", "Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item(l("conversation.menu.delete", "Delete"), #selector(NSText.delete(_:))),
            item(l("conversation.menu.selectAll", "Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu(l("conversation.menu.search", "Search"), [
                item(MacConversationCommands.find),
                item(MacConversationCommands.findNext),
                item(MacConversationCommands.findPrevious),
            ]),
            .separator(),
            submenu(l("conversation.menu.spelling", "Spelling and Grammar"), [
                item(l("conversation.menu.showSpelling", "Show Spelling and Grammar"), #selector(NSText.showGuessPanel(_:)), ":"),
                item(l("conversation.menu.checkSpelling", "Check Document Now"), #selector(NSText.checkSpelling(_:)), ";"),
            ]),
            submenu(l("conversation.menu.speech", "Speech"), [
                item(l("conversation.menu.startSpeaking", "Start Speaking"), #selector(NSTextView.startSpeaking(_:))),
                item(l("conversation.menu.stopSpeaking", "Stop Speaking"), #selector(NSTextView.stopSpeaking(_:))),
            ]),
            .separator(),
            item(MacConversationCommands.send),
            item(MacConversationCommands.reply),
            item(MacConversationCommands.continueReply),
            item(MacConversationCommands.tapback),
            item(MacConversationCommands.editLast),
            .separator(),
            item(l("conversation.menu.emojiAndSymbols", "Emoji & Symbols"), #selector(NSApplication.orderFrontCharacterPalette(_:))),
        ]))
        bar.addItem(submenu(l("conversation.menu.view", "View"), [
            item(MacConversationCommands.textBigger),
            item(MacConversationCommands.textNormal),
            item(MacConversationCommands.textSmaller),
            .separator(),
            item(MacConversationCommands.showTimes),
            item(MacConversationCommands.editBackground),
            .separator(),
            // Messages lists the filters flat under a "Filter By" header.
            .sectionHeader(title: l("conversation.menu.filterBy", "Filter By")),
            item(MacConversationCommands.filterUnread),
            item(MacConversationCommands.filterDrafts),
            item(MacConversationCommands.filterSendLater),
            .separator(),
            item(l("conversation.menu.enterFullScreen", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        bar.addItem(submenu(l("conversation.menu.conversation", "Conversation"), [
            item(MacConversationCommands.showDetails),
            item(MacConversationCommands.showContactCard),
            .separator(),
            item(MacConversationCommands.markUnread),
            item(MacConversationCommands.markAllRead),
            item(MacConversationCommands.hideAlerts),
            .separator(),
            item(MacConversationCommands.deleteConversation),
        ]))
        bar.addItem(submenu(l("conversation.textFormat.menu", "Format"), MacConversationCommands.textStyles.map { item($0) } + [
            .separator(),
            .sectionHeader(title: l("conversation.textEffects.title", "Text Effects")),
        ] + MacConversationCommands.textEffects.map { item($0) }))
        let window = submenu(l("conversation.menu.window", "Window"), [
            item(l("conversation.menu.minimize", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(l("conversation.menu.zoom", "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(MacConversationCommands.nextConversation),
            item(MacConversationCommands.previousConversation),
            .separator(),
            item(l("conversation.menu.bringAllToFront", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        bar.addItem(window)
        NSApp.windowsMenu = window.submenu
        return bar
    }
}
#endif
