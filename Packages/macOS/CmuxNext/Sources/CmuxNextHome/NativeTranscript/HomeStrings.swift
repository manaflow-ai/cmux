import CmuxHomeCore
import Foundation

/// Every user-facing string of the Home module (Localizable.xcstrings). The
/// transcript's own strings are MessagesLab's (CmuxMessagesLab's catalogs).
enum HomeStrings {
    static var attachFiles: String { String(localized: "home.composer.attach", defaultValue: "Attach Files", bundle: .module) }
    static var attachPrompt: String { String(localized: "home.composer.attach.prompt", defaultValue: "Attach", bundle: .module) }
    static var removeAttachment: String {
        String(localized: "home.composer.attach.remove", defaultValue: "Remove Attachment", bundle: .module)
    }
    static var pastedItem: String { String(localized: "home.composer.attach.pasted", defaultValue: "Pasted item", bundle: .module) }
    static var attachFailed: String {
        String(localized: "home.composer.attach.failed", defaultValue: "The file couldn’t be attached.", bundle: .module)
    }
    /// While a drop's files are still on their way from their app (a screenshot thumbnail, Photos, a browser).
    static var attachPending: String {
        String(localized: "home.composer.attach.pending", defaultValue: "Adding the dropped files…", bundle: .module)
    }
    static func attachUnsupported(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.refused", defaultValue: "“%@” can’t be attached.", bundle: .module), name)
    }
    static func attachFolder(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.folder",
                              defaultValue: "“%@” is a folder. Attach the files in it, or a ZIP of the folder.", bundle: .module), name)
    }
    static func attachTooLarge(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.tooLarge", defaultValue: "“%@” is larger than 100 MB.", bundle: .module), name)
    }
    static func attachTooLargeAny() -> String {
        String(localized: "home.composer.attach.tooLargeAny", defaultValue: "A file is larger than 100 MB.", bundle: .module)
    }
    static func attachEmpty(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.empty", defaultValue: "“%@” is empty.", bundle: .module), name)
    }
    static func attachInvalidName(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.invalidName", defaultValue: "“%@” is not a valid file name.",
                              bundle: .module), name)
    }
    static func attachLocationNotRemoved(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.locationNotRemoved",
                              defaultValue: "Location data couldn’t be removed from “%@”, so it was not attached.", bundle: .module), name)
    }
    /// Why a send shows "Not Delivered": the refusal's own notice (``rejection(_:)``), which says
    /// why an owner took no files.
    static func notDeliveredReason(_ rejection: HomeRejection) -> String {
        Self.rejection(rejection)
    }
    /// Why an owner took no files, or nil for any other refusal. A file has nowhere to go on these
    /// owners, and a path on this Mac means nothing to them, so the person removes the attachments.
    private static func attachmentRefusalReason(_ rejection: HomeRejection) -> String? {
        switch rejection {
        // cmux Cloud keeps text only (`HomeSourceRouter.upload` names the Cloud owner).
        case .invalid("cloud_attachments_unsupported"):
            String(localized: "home.send.attachmentsCloud",
                   defaultValue: "cmux Cloud conversations keep text only, so files can’t be sent here. Remove the attachments and send again.",
                   bundle: .module)
        // A cmux daemon owner without `local-attachments-v1`: an older cmux on the machine that owns the conversation.
        case .invalid("attachments_unsupported"):
            String(localized: "home.send.attachmentsNeedNewerCmux",
                   defaultValue: "The cmux that owns this conversation is too old to store files. Update cmux there, or remove the attachments and send again.",
                   bundle: .module)
        // Any other owner with no file storage (`HomeSource.upload`'s default).
        case .invalid("attachments unsupported"):
            String(localized: "home.send.attachmentsUnsupported",
                   defaultValue: "This conversation doesn’t store files. Remove the attachments and send again.", bundle: .module)
        default: nil
        }
    }
    static var unanswered: String {
        String(localized: "home.send.unanswered", defaultValue: "A change may not have gone through. Check your connection.",
               bundle: .module)
    }
    /// The composer notice for a send the owner refused after it left the
    /// composer (a resumed upload, a resend).
    static func rejection(_ rejection: HomeRejection) -> String {
        if let reason = attachmentRefusalReason(rejection) { return reason }
        return switch rejection {
        case .notAuthorized:
            String(localized: "home.send.refused.notAuthorized", defaultValue: "You can’t send messages in this conversation.",
                   bundle: .module)
        case .rateLimited:
            String(localized: "home.send.refused.rateLimited", defaultValue: "Too many messages. Try again in a moment.", bundle: .module)
        case .ownerUnreachable, .indeterminate, .invalid:
            String(localized: "home.send.refused.generic", defaultValue: "A message couldn’t be sent.", bundle: .module)
        }
    }
    static func attachTooMany(_ limit: Int) -> String {
        String(format: String(localized: "home.composer.attach.tooMany", defaultValue: "Too many attachments. Limit: %lld.",
                              bundle: .module), limit)
    }
    /// The notice for each reason the data side refuses an attachment.
    static func attachmentRefusal(_ refusal: HomeAttachmentError, name: String? = nil) -> String {
        switch refusal {
        case .typeRefused(_, let file): attachUnsupported(name ?? file)
        case .folder(let file): attachFolder(name ?? file)
        case .tooLarge: name.map(attachTooLarge) ?? attachTooLargeAny()
        case .empty(let file): attachEmpty(name ?? file)
        case .invalidName(let file): attachInvalidName(name ?? file)
        case .locationNotRemoved(let file): attachLocationNotRemoved(name ?? file)
        case .tooManyParts(let limit): attachTooMany(limit - 1)
        }
    }
    static var playVideo: String { String(localized: "home.video.play", defaultValue: "Play Video", bundle: .module) }
    static var pauseVideo: String { String(localized: "home.video.pause", defaultValue: "Pause Video", bundle: .module) }
    static var firstRunOpenTerminal: String {
        String(localized: "home.firstRun.openTerminal", defaultValue: "Open a terminal", bundle: .module)
    }
    static var firstRunStartAgent: String {
        String(localized: "home.firstRun.startAgent", defaultValue: "Start an agent", bundle: .module)
    }
    /// The first-run panel's title under the Chief's character (`HomeFirstRunHero`).
    static var firstRunHeroTitle: String {
        String(localized: "home.firstRun.hero.title", defaultValue: "Your Chief", bundle: .module)
    }
    /// What the Chief does today, under the title.
    static var firstRunHeroBody: String {
        String(localized: "home.firstRun.hero.body",
               defaultValue: "Tell it what you want done. It handles quick things itself and hands longer work to agents, each in its own workspace you can watch and join. It reports back here.",
               bundle: .module)
    }
    /// The Chief's first-open message above the hero: what Chief is, what it does with agents and
    /// workspaces, and how to start (`HomeFirstRunIntro`).
    static var firstRunIntro: String {
        String(localized: "home.firstRun.intro",
               defaultValue: "Hi, I'm Chief, your assistant in cmux. Tell me what you want done.\nI handle quick things myself. Bigger jobs go to agents, each in its own workspace you can watch and join.\nTo start, type below or pick a suggestion.",
               bundle: .module)
    }
    /// A new Chief's first message when the person has other Chiefs: it asks what to focus on.
    static var chiefIntroFocus: String {
        String(localized: "home.firstRun.introFocus",
               defaultValue: "Hi, I'm a new Chief. What should I focus on?\nTell me a project, a repo or a kind of work, and I'll stick to it so I don't overlap with your other Chiefs.",
               bundle: .module)
    }
    /// The text of the intro `kind` (``ChiefIntroStore`` picks it).
    static func chiefIntro(_ kind: ChiefIntroKind) -> String {
        switch kind {
        case .welcome: firstRunIntro
        case .askFocus: chiefIntroFocus
        }
    }
    /// The first-run row that shows the floating Chief pet (`home.toggleChiefPet`).
    static var firstRunShowPet: String {
        String(localized: "home.firstRun.showPet", defaultValue: "Show Chief Pet", bundle: .module)
    }
    /// The same row while the pet shows.
    static var firstRunHidePet: String {
        String(localized: "home.firstRun.hidePet", defaultValue: "Hide Chief Pet", bundle: .module)
    }
    /// The heading of the first-run "Switching" card (`HomeFirstRunSwitchCard`).
    static var switchKeysHeader: String {
        String(localized: "home.firstRun.switchKeys.header", defaultValue: "Switching", bundle: .module)
    }
    /// The card's button that hides it for good.
    static var switchKeysHide: String {
        String(localized: "home.firstRun.switchKeys.hide", defaultValue: "Hide", bundle: .module)
    }
    static var switchKeysTabs: String {
        String(localized: "home.firstRun.switchKeys.tabs", defaultValue: "Tab 1–9 (like VS Code)", bundle: .module)
    }
    static var switchKeysWorkspaces: String {
        String(localized: "home.firstRun.switchKeys.workspaces", defaultValue: "Workspace 1–9", bundle: .module)
    }
    static var switchKeysNextTab: String {
        String(localized: "home.firstRun.switchKeys.nextTab", defaultValue: "Previous / next tab", bundle: .module)
    }
    static var switchKeysNextWorkspace: String {
        String(localized: "home.firstRun.switchKeys.nextWorkspace", defaultValue: "Previous / next workspace", bundle: .module)
    }
    static var switchKeysFocus: String {
        String(localized: "home.firstRun.switchKeys.focus", defaultValue: "Focus back / forward", bundle: .module)
    }
    /// The one-line note when Mission Control's Switch to Desktop takes the tab keys.
    static var switchKeysDesktopConflict: String {
        String(localized: "home.firstRun.switchKeys.desktopConflict",
               defaultValue: "Mission Control uses these keys to switch desktops.", bundle: .module)
    }
    /// The note's button: opens System Settings > Keyboard > Keyboard Shortcuts.
    static var switchKeysOpenSettings: String {
        String(localized: "home.firstRun.switchKeys.openSettings", defaultValue: "Keyboard Shortcuts…", bundle: .module)
    }
    /// The heading over the first-run panel's agent rows.
    static var firstRunAgentsHeader: String {
        String(localized: "home.firstRun.agents", defaultValue: "Your agents", bundle: .module)
    }
    /// One short word for what an agent row's agent is doing.
    static func firstRunAgentStatus(_ status: HomeAgentGlance.Status) -> String {
        switch status {
        case .needsYou: String(localized: "home.firstRun.agent.needsYou", defaultValue: "Needs you", bundle: .module)
        case .failed: String(localized: "home.firstRun.agent.failed", defaultValue: "Failed", bundle: .module)
        case .done: String(localized: "home.firstRun.agent.done", defaultValue: "Done", bundle: .module)
        case .idle: String(localized: "home.firstRun.agent.idle", defaultValue: "Idle", bundle: .module)
        case .working: String(localized: "home.firstRun.agent.working", defaultValue: "Working", bundle: .module)
        }
    }
    static var conversations: String { String(localized: "home.list.title", defaultValue: "Conversations", bundle: .module) }
}
