import CmuxHomeCore
import Foundation

/// Every user-facing string of the classic Chief UI (`Resources/Localizable.xcstrings`).
/// The transcript and conversation list strings are MessagesLab's own catalogs.
enum ChiefStrings {
    // MARK: Names

    /// The persistent Home destination in cmux's left sidebar.
    static var home: String {
        String(localized: "sidebar.home.title", defaultValue: "Home")
    }

    /// The Chief's name: a new conversation's Chief and an untitled row's title.
    /// A proper name, never translated (cmux-next keeps "Chief" in every locale).
    static let chiefName = "Chief"
    static var unavailable: String {
        String(localized: "chief.unavailable", defaultValue: "Chief couldn’t start. Its conversations folder can’t be opened.")
    }

    // MARK: First run

    static var firstRunHeadline: String {
        String(localized: "chief.firstRun.headline", defaultValue: "What should we do?")
    }
    static var firstRunCloudMachine: String {
        String(localized: "chief.firstRun.prompt.cloudMachine", defaultValue: "Set up a cloud machine")
    }
    static var firstRunCodexAgents: String {
        String(localized: "chief.firstRun.prompt.codexAgents", defaultValue: "Send 3 Codex agents on these issues")
    }
    static var firstRunFontSize: String {
        String(localized: "chief.firstRun.prompt.fontSize", defaultValue: "Make my font bigger")
    }
    static var firstRunAgentStatus: String {
        String(localized: "chief.firstRun.prompt.agentStatus", defaultValue: "What are my agents doing?")
    }
    /// The memory chip's label.
    static var firstRunRemember: String {
        String(localized: "chief.firstRun.prompt.rememberPreference", defaultValue: "Remember a preference")
    }
    /// What the memory chip puts in the message box, for the user to finish
    /// (a space and the cursor follow it).
    static var firstRunRememberFill: String {
        String(localized: "chief.firstRun.prompt.rememberFill", defaultValue: "Remember that I prefer")
    }
    static var firstRunOpenTerminal: String {
        String(localized: "chief.firstRun.openTerminal", defaultValue: "Open a terminal")
    }
    static var firstRunStartAgent: String {
        String(localized: "chief.firstRun.startAgent", defaultValue: "Start an agent")
    }
    /// VoiceOver help on a starter row that sends at once.
    static var firstRunSendsHelp: String {
        String(localized: "chief.firstRun.sendsHelp", defaultValue: "Sends this to Chief")
    }
    /// VoiceOver help on a starter row that only fills the message box.
    static var firstRunFillsHelp: String {
        String(localized: "chief.firstRun.fillsHelp", defaultValue: "Puts this in the message box to finish")
    }

    // MARK: Settings panel

    static var settingsTitle: String { String(localized: "chief.settings.title", defaultValue: "Chief Settings") }
    static var settingsPillHelp: String {
        String(localized: "chief.settings.pillHelp", defaultValue: "Shows or hides Chief’s settings")
    }
    static var settingsHarness: String { String(localized: "chief.settings.harness", defaultValue: "Harness") }
    static var settingsModel: String { String(localized: "chief.settings.model", defaultValue: "Model") }
    static var settingsEffort: String { String(localized: "chief.settings.effort", defaultValue: "Effort") }
    static var settingsDangerousPermissions: String {
        String(localized: "chief.settings.dangerousPermissions", defaultValue: "Skip permission prompts")
    }
    static var settingsDangerousPermissionsHelp: String {
        String(localized: "chief.settings.dangerousPermissions.help",
               defaultValue: "Allows the selected agent to run commands and make changes without asking. Off by default; applies to new turns.")
    }
    static var settingsDangerousPermissionsPromptTitle: String {
        String(localized: "chief.settings.dangerousPermissions.prompt.title", defaultValue: "Skip permission prompts?")
    }
    static var settingsDangerousPermissionsPromptMessage: String {
        String(localized: "chief.settings.dangerousPermissions.prompt.message",
               defaultValue: "The selected agent can run commands and make changes without approval cards. This is a dangerous setting.")
    }
    static var settingsDangerousPermissionsTurnOn: String {
        String(localized: "chief.settings.dangerousPermissions.prompt.turnOn", defaultValue: "Turn On")
    }
    static var settingsCancel: String {
        String(localized: "chief.settings.dangerousPermissions.prompt.cancel", defaultValue: "Cancel")
    }
    static var settingsDefault: String { String(localized: "chief.settings.default", defaultValue: "Default") }
    static var settingsNextTurn: String {
        String(localized: "chief.settings.nextTurn", defaultValue: "Changes apply from the next turn.")
    }
    /// An effort level's name in the picker; an unknown id shows as itself.
    static func effortName(_ id: String) -> String {
        switch id {
        case "low": return String(localized: "chief.settings.effort.low", defaultValue: "Low")
        case "medium": return String(localized: "chief.settings.effort.medium", defaultValue: "Medium")
        case "high": return String(localized: "chief.settings.effort.high", defaultValue: "High")
        case "xhigh": return String(localized: "chief.settings.effort.xhigh", defaultValue: "Extra High")
        case "max": return String(localized: "chief.settings.effort.max", defaultValue: "Max")
        default: return id
        }
    }
    static var settingsAvatar: String { String(localized: "chief.settings.avatar", defaultValue: "Avatar") }
    /// The sidebar Home row's status while a Chief runs a turn.
    static var homeRowWorking: String {
        String(localized: "sidebar.chiefHome.working", defaultValue: "Working…")
    }
    /// The sidebar Home row's status while a Chief waits on the user's approval.
    static var homeRowNeedsYou: String {
        String(localized: "sidebar.chiefHome.needsYou", defaultValue: "Needs you")
    }
    /// The sidebar Home row's spoken status when Chief has unread replies.
    static var homeRowUnread: String {
        String(localized: "sidebar.chiefHome.unread", defaultValue: "Unread replies")
    }
    /// The sidebar's back row while Home is selected.
    static var backToWorkspaces: String {
        String(localized: "sidebar.chiefHome.backToWorkspaces", defaultValue: "Workspaces")
    }
    /// The back row's tooltip; `keys` is the Open Chief shortcut (it toggles Home), nil when unbound.
    static func backToWorkspacesTooltip(keys: String?) -> String {
        guard let keys else {
            return String(localized: "sidebar.chiefHome.backToWorkspaces.tooltip", defaultValue: "Back to workspaces")
        }
        return String(format: String(localized: "sidebar.chiefHome.backToWorkspaces.tooltipShortcut",
                                     defaultValue: "Back to workspaces (%@)"), keys)
    }
    /// A conversation row's preview before its first message.
    static var conversationEmptyPreview: String {
        String(localized: "chief.list.emptyPreview", defaultValue: "Ask Chief anything")
    }
    /// A conversation row's preview when the newest message is only attachments.
    static var conversationAttachmentPreview: String {
        String(localized: "chief.list.attachmentPreview", defaultValue: "Attachment")
    }
    static var settingsAvatarChoosePicture: String {
        String(localized: "chief.settings.avatar.choosePicture", defaultValue: "Choose Picture…")
    }
    static var settingsAvatarRemovePicture: String {
        String(localized: "chief.settings.avatar.removePicture", defaultValue: "Remove Picture")
    }
    static var settingsAvatarPickerPrompt: String {
        String(localized: "chief.settings.avatar.pickerPrompt", defaultValue: "Choose")
    }
    static var settingsAvatarPictureFailed: String {
        String(localized: "chief.settings.avatar.pictureFailed", defaultValue: "That picture could not be used. Choose another image.")
    }
    /// The avatar's secondary choice under Choose Picture…: text drawn in the circle.
    static var settingsAvatarTextLabel: String {
        String(localized: "chief.settings.avatar.textLabel", defaultValue: "Or show an emoji or initials")
    }
    static var settingsAvatarPlaceholder: String {
        String(localized: "chief.settings.avatar.textPlaceholder", defaultValue: "For example, 😺 or AB")
    }
    static var settingsMemory: String { String(localized: "chief.settings.memory", defaultValue: "Memory") }
    static var settingsMemoryNote: String {
        String(localized: "chief.settings.memory.note",
               defaultValue: "Chief reads these files when a conversation starts. You can edit them.")
    }
    static var settingsEditProfile: String {
        String(localized: "chief.settings.memory.editProfile", defaultValue: "Edit About You…")
    }
    static var settingsEditInstructions: String {
        String(localized: "chief.settings.memory.editInstructions", defaultValue: "Edit Instructions…")
    }
    static var settingsShowMemoryFolder: String {
        String(localized: "chief.settings.memory.showFolder", defaultValue: "Show in Finder")
    }
    static var settingsConversation: String {
        String(localized: "chief.settings.conversation", defaultValue: "Conversation")
    }

    // MARK: Memory editor

    static var memoryProfileTitle: String { String(localized: "chief.memory.profile.title", defaultValue: "About You") }
    static var memoryInstructionsTitle: String {
        String(localized: "chief.memory.instructions.title", defaultValue: "Instructions for Chief")
    }
    static var memorySave: String { String(localized: "chief.memory.save", defaultValue: "Save") }
    static var memoryCancel: String { String(localized: "chief.memory.cancel", defaultValue: "Cancel") }
    static var memorySaveFailed: String {
        String(localized: "chief.memory.saveFailed", defaultValue: "The file couldn’t be saved.")
    }

    // MARK: Conversation list

    static var newConversation: String {
        String(localized: "chief.conversation.new", defaultValue: "New Conversation")
    }
    static var newConversationFailed: String {
        String(localized: "chief.conversation.newFailed", defaultValue: "A new conversation couldn’t be started.")
    }
    static var conversationsList: String {
        String(localized: "chief.conversation.list", defaultValue: "Chief Conversations")
    }
    static var conversationsExpanded: String {
        String(localized: "chief.conversation.expanded", defaultValue: "Expanded")
    }
    static var conversationsCollapsed: String {
        String(localized: "chief.conversation.collapsed", defaultValue: "Collapsed")
    }
    /// Tooltip for the header action that mirrors this conversation in the right Dock.
    static var openInDock: String {
        String(localized: "chief.conversation.openInDock", defaultValue: "Open Chief in Dock")
    }

    // MARK: Composer notices

    static var attachPrompt: String { String(localized: "chief.attach.prompt", defaultValue: "Attach") }
    static var pastedItem: String { String(localized: "chief.attach.pasted", defaultValue: "Pasted item") }
    static var attachFailed: String {
        String(localized: "chief.attach.failed", defaultValue: "The file couldn’t be attached.")
    }
    static func attachUnsupported(_ name: String) -> String {
        String(format: String(localized: "chief.attach.unsupported",
                              defaultValue: "“%@” can’t be attached. You can attach photos, videos, audio, PDFs, text files and ZIP archives."),
               name)
    }
    static func attachTooLarge(_ name: String) -> String {
        String(format: String(localized: "chief.attach.tooLarge", defaultValue: "“%@” is larger than 100 MB."), name)
    }
    static var attachTooLargeAny: String {
        String(localized: "chief.attach.tooLargeAny", defaultValue: "A file is larger than 100 MB.")
    }
    static func attachEmpty(_ name: String) -> String {
        String(format: String(localized: "chief.attach.empty", defaultValue: "“%@” is empty."), name)
    }
    static func attachInvalidName(_ name: String) -> String {
        String(format: String(localized: "chief.attach.invalidName", defaultValue: "“%@” is not a valid file name."), name)
    }
    static func attachLocationNotRemoved(_ name: String) -> String {
        String(format: String(localized: "chief.attach.locationNotRemoved",
                              defaultValue: "Location data couldn’t be removed from “%@”, so it was not attached."), name)
    }
    static var attachTooMany: String {
        String(localized: "chief.attach.tooMany", defaultValue: "That’s too many attachments for one message.")
    }

    /// The notice for each reason an attachment is refused.
    static func attachmentRefusal(_ refusal: HomeAttachmentError, name: String? = nil) -> String {
        switch refusal {
        case .typeRefused(_, let file): return attachUnsupported(name ?? file)
        case .tooLarge: return name.map(attachTooLarge) ?? attachTooLargeAny
        case .empty(let file): return attachEmpty(name ?? file)
        case .invalidName(let file): return attachInvalidName(name ?? file)
        case .locationNotRemoved(let file): return attachLocationNotRemoved(name ?? file)
        case .tooManyParts: return attachTooMany
        }
    }

    static var unanswered: String {
        String(localized: "chief.send.unanswered", defaultValue: "A change may not have gone through.")
    }

    /// A Cloud result card's Open Workspace failed; `machine` is the machine id.
    static func cloudOpenFailed(_ machine: String) -> String {
        String(localized: "chief.cloud.openFailed", defaultValue: "Couldn’t open the workspace on \(machine).")
    }

    /// The notice shown when the Cloud result card cannot open its live display.
    static func cloudDesktopOpenFailed(_ machine: String) -> String {
        String(localized: "chief.cloud.desktopOpenFailed", defaultValue: "Couldn’t open the desktop on \(machine).")
    }

    /// A send refused after it left the composer.
    static func rejection(_ rejection: HomeRejection) -> String {
        switch rejection {
        case .notAuthorized:
            return String(localized: "chief.send.refused.notAuthorized", defaultValue: "You can’t send messages in this conversation.")
        case .rateLimited:
            return String(localized: "chief.send.refused.rateLimited", defaultValue: "Too many messages. Try again in a moment.")
        case .ownerUnreachable, .indeterminate, .invalid:
            return String(localized: "chief.send.refused.generic", defaultValue: "A message couldn’t be sent.")
        }
    }
}
