#if os(macOS)
import AppKit

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
}

/// Responders that can refuse a command (a disabled menu item, a beep).
@MainActor
protocol MacConversationCommandValidating: AnyObject {
    func canPerform(_ action: Selector) -> Bool
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

    /// Commands the conversation window answers itself, ahead of any host
    /// app's menus or shortcut monitors.
    static let keyed: [MacConversationCommand] = [send, reply, continueReply, tapback, editLast, find, nextConversation, previousConversation]

    static func command(matching event: NSEvent) -> MacConversationCommand? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key: String
        switch event.keyCode {
        case 48: key = "\t"
        case 36, 76: key = "\r"
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
        if let validating = target as? any MacConversationCommandValidating, !validating.canPerform(command.action) {
            NSSound.beep()
            return true
        }
        return NSApp.sendAction(command.action, to: target, from: window)
    }
}

/// The conversation window: Messages' shortcuts reach the conversation
/// before the host app's menus.
final class MacConversationWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let command = MacConversationCommands.command(matching: event), MacConversationCommands.perform(command, in: self) {
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
            item(command.title(), command.action, command.key, command.modifiers)
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            parent.submenu = menu
            return parent
        }
        let l = { (key: String.LocalizationValue) in String(localized: key, bundle: .module) }
        let bar = NSMenu()

        let services = NSMenu(title: l("conversation.menu.services"))
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: l("conversation.menu.services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        bar.addItem(submenu(appName, [
            item(String(format: l("conversation.menu.about"), appName), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            servicesItem,
            .separator(),
            item(String(format: l("conversation.menu.hide"), appName), #selector(NSApplication.hide(_:)), "h"),
            item(l("conversation.menu.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(l("conversation.menu.showAll"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(format: l("conversation.menu.quit"), appName), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        bar.addItem(submenu(l("conversation.menu.file"), [
            item(l("conversation.menu.close"), #selector(NSWindow.performClose(_:)), "w"),
        ]))
        bar.addItem(submenu(l("conversation.menu.editMenu"), [
            item(l("conversation.menu.undo"), Selector(("undo:")), "z"),
            item(l("conversation.menu.redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(l("conversation.menu.cut"), #selector(NSText.cut(_:)), "x"),
            item(l("conversation.menu.copy"), #selector(NSText.copy(_:)), "c"),
            item(l("conversation.menu.paste"), #selector(NSText.paste(_:)), "v"),
            item(l("conversation.menu.pasteAndMatchStyle"), #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item(l("conversation.menu.delete"), #selector(NSText.delete(_:))),
            item(l("conversation.menu.selectAll"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu(l("conversation.menu.search"), [item(MacConversationCommands.find)]),
            .separator(),
            submenu(l("conversation.menu.spelling"), [
                item(l("conversation.menu.showSpelling"), #selector(NSText.showGuessPanel(_:)), ":"),
                item(l("conversation.menu.checkSpelling"), #selector(NSText.checkSpelling(_:)), ";"),
            ]),
            submenu(l("conversation.menu.speech"), [
                item(l("conversation.menu.startSpeaking"), #selector(NSTextView.startSpeaking(_:))),
                item(l("conversation.menu.stopSpeaking"), #selector(NSTextView.stopSpeaking(_:))),
            ]),
            .separator(),
            item(MacConversationCommands.send),
            item(MacConversationCommands.reply),
            item(MacConversationCommands.continueReply),
            item(MacConversationCommands.tapback),
            item(MacConversationCommands.editLast),
            .separator(),
            item(l("conversation.menu.emojiAndSymbols"), #selector(NSApplication.orderFrontCharacterPalette(_:))),
        ]))
        bar.addItem(submenu(l("conversation.menu.view"), [
            item(MacConversationCommands.showTimes),
            .separator(),
            item(l("conversation.menu.enterFullScreen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let window = submenu(l("conversation.menu.window"), [
            item(l("conversation.menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(l("conversation.menu.zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(MacConversationCommands.nextConversation),
            item(MacConversationCommands.previousConversation),
            .separator(),
            item(l("conversation.menu.bringAllToFront"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        bar.addItem(window)
        NSApp.windowsMenu = window.submenu
        return bar
    }
}
#endif
