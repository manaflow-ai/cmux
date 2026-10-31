// DEBUG and Demo builds only: no demo plumbing ships in Production.
#if DEBUG
import Foundation
import Observation

/// DEBUG demo driver plumbing (launch argument `-CmuxMobileDemo chat-feed`). A script
/// posts commands; the screen that owns the target performs them through its
/// normal code paths (scroll positions, the question reducer, the composer),
/// so the recording shows real behavior. Release builds never post commands.
@MainActor
@Observable
public final class DemoDirector {
    public static let shared = DemoDirector()

    public enum Command: Hashable, Sendable {
        case feedScroll(toEvent: String)
        case feedScrollTop
        case feedExpand(event: String)
        /// Picks option ids per item (in item order), then submits.
        case answerQuestion(id: String, picks: [[String]])
        case feedReply(event: String, text: String)
        case feedOpen(event: String)
        case chatSend(String)
        case chatScroll(toTop: Bool)
        /// Opens or closes the transcript's tool row nearest the middle of the screen, as a tap does.
        case chatToggleDisclosure
        case chatPermission(optionKind: String)
        case chatOpenChanges
        case chatOpenFirstFile
        case diffSetSplit(Bool)
        case diffExpandFirst
        case diffMarkViewed
        case navigateBack
        // ACP parity demo (agent chat).
        case chatOpenArtifacts
        case artifactsFilter(String)
        case artifactsLayout(grid: Bool)
        case artifactsOpen(String)
        case artifactsSource(Bool)
        case artifactsBack
        case artifactsClose
        /// "subagents", "checkpoints", "handoff", or a subagent's name.
        case chatOpenParity(String)
        case parityClose
        case checkpointRestore(id: String)
        case checkpointConfirm
        case handoffPick(id: String)
        case handoffFill(reference: String)
        case handoffStart
        /// Setup's footer Sign out, then its confirmation.
        case setupSignOut
        case setupConfirmSignOut
        // Feed swipe actions and composer attachments.
        case feedSwipe(event: String, edge: String)
        case feedSwipeAction(event: String, action: String)
        case feedSwipeClose
        // Onboarding and setup (`-cmux-mobile-demo onboarding`).
        case onboardingOpenEmail
        case onboardingTypeEmail(String)
        case onboardingSendCode
        case onboardingTypeCode(String)
        case setupPickTeam(index: Int)
        case setupNotNow
        // Team appearance editor.
        case editorColor(hex: String)
        case editorEmoji(String)
        case editorDone
    }

    public private(set) var command: Command?
    public private(set) var serial = 0
    public private(set) var isActive = false

    public init() {}

    public func post(_ command: Command) {
        isActive = true
        self.command = command
        serial &+= 1
    }

    /// Returns the current command when it matches, so a view handles each command once.
    public func take<T>(_ match: (Command) -> T?) -> T? {
        guard let command else { return nil }
        return match(command)
    }
}
#endif
