public import CmuxNextDesign
import MessagesLabHome

/// Debug Settings of the Home transcript (DEV and NIGHTLY only; Release and
/// RC never activate the store, so they keep the defaults: the flight
/// recorder's are off; product defaults such as `firstRunHero` and `launchIntoHome` are on, and
/// Release ships them on).
///
/// The flight recorder is MessagesLab's (`HomeFlightRecorder`): after a
/// send it samples every frame of the transcript, and on a blink (a row
/// without pixels, a jump, a gap, an unfilled bubble) it writes the last
/// ~10 s to ~/Library/Logs/<app>/blink-<time>/. An opt-in in DEV and
/// NIGHTLY until MessagesLab's recorder costs at most 0.3 ms a frame (it cost
/// more main-thread time than a send); window captures are a separate opt-in.
public nonisolated struct HomeTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "home", title: "Home", symbol: "house", order: 43)

    private static let devDefault = false

    public static let flightRecorder = Tunable<Bool>.toggle(
        "home.flightRecorder", section, "Flight recorder",
        help: "Samples the Home transcript after a send and writes the last 10 s to ~/Library/Logs/<app>/blink-<time>/ when a row blinks, jumps or leaves a gap. Also Debug > Save Last 10 Seconds.",
        default: devDefault, code: "HomeTunables.flightRecorder")

    public static let flightRecorderCaptures = Tunable<Bool>.toggle(
        "home.flightRecorder.captures", section, "Flight recorder window captures",
        help: "A flight recorder dump also saves about 0.5 s of captures of the window (pictures of your conversation). Needs Flight recorder.",
        default: devDefault, code: "HomeTunables.flightRecorderCaptures")

    /// The empty Chief conversation's hero (`HomeFirstRunHero`): the Chief's character and what it
    /// does, over the rows. On by default (Leo 2026-10-19); off is the rows-only panel from before.
    public static let firstRunHero = Tunable<Bool>.toggle(
        "home.firstRun.hero", section, "Chief front page hero",
        help: "The empty Chief conversation shows the Chief's character and two lines about what it does above its rows. Off shows only the rows.",
        default: true, code: "HomeTunables.firstRunHero")

    /// A launch with no workspace of the person's own lands on Home (the Chief's workspace) instead
    /// of making an empty New Tab workspace (`FirstWorkspaceLaunch`; Leo 2026-10-19). Off restores
    /// the New Tab workspace.
    public static let launchIntoHome = Tunable<Bool>.toggle(
        "home.launchIntoHome", section, "First launch opens Home",
        help: "With no workspace of your own, launch shows Home and its Chief instead of making an empty workspace on its New Tab page.",
        default: true, code: "HomeTunables.launchIntoHome")

    /// The Chief's running indicator above its typing dots (`HomeTurnProgress`): the folded steps, the
    /// Chief's newest thought and the step running now (default, Leo 2026-10-20), or the one line before.
    public static let turnProgress = Tunable<HomeTurnProgressChoice>.choice(
        "home.turnProgress", section, "Chief running indicator",
        help: "While the Chief works: its finished steps folded into one row (\"Ran 3 commands ›\"), its newest thought, and the step running now. Steps leaves out the thought; One line is the step running now only.",
        default: .narrated, code: "HomeTunables.turnProgress")

    /// An agent's pipe tables in the transcript (MessagesLabHome `HomeTableRowProvider`): a card at
    /// the chat's full width with real column widths, and an assignment table (an owner column of
    /// subagent ids) as the Chief's plan card. On by default (Leo 2026-10-20); off keeps the table as
    /// Markdown text in the bubble. Conversations opened after a change follow it.
    public static let richTables = Tunable<Bool>.toggle(
        "home.richTables", section, "Rich tables and plan cards",
        help: "Tables in the Chief's replies break out of the bubble as full-width cards, and assignment tables (who does what) show as a plan card with owner chips, live states and pull requests. Off keeps tables as text in the bubble.",
        default: true, code: "HomeTunables.richTables")

    /// The message box's mic (`HomeVoiceDictation`): on-device dictation into the field. On by
    /// default (Leo 2026-10-20); off shows Messages' drawn waveform, which does nothing.
    public static let voiceInput = Tunable<Bool>.toggle(
        "home.voiceInput", section, "Mic button in the message box",
        help: "The mic in the empty message box dictates into it (on-device speech). Off shows the drawn waveform instead.",
        default: true, code: "HomeTunables.voiceInput")

    /// The chat's header over the transcript (MessagesLabHome `HeaderGlassView`): the Chief's avatar
    /// centered and its "Chief >" pill on a glass band, as Messages; the pill opens the Chief's
    /// settings. On by default (Lawrence 2026-10-23: "chief centered profile pic is gone, chief
    /// settings gone"; #23796 had turned it off on 2026-10-21). Off: no header, the rows start at the
    /// top and fade out there. Conversations opened after a change follow it.
    public static let chatHeader = Tunable<Bool>.toggle(
        "home.chatHeader", section, "Avatar and name over the chat",
        help: "The chat shows the Chief's avatar and name pill on a glass band at its top, as Messages does. Off: no header, and the messages fade out at the top as they scroll away.",
        default: true, code: "HomeTunables.chatHeader")

    /// How the chat ends at its top under the avatar and the "Chief >" pill (MessagesLabHome
    /// ``HomeTopFadeStyle``), switched live in every open Home chat. The glass band by default
    /// (#23796's look) until Lawrence picks one (2026-10-23: "make variations of how we do fade at
    /// top in chief"). Only with ``chatHeader`` on; no header keeps its own short fade.
    public static let topFadeStyle = Tunable<HomeTopFadeChoice>.choice(
        "home.topFadeStyle", section, "Top of the chat",
        help: "How the messages end at the top of the chat as they scroll under the avatar and name pill: a glass band, a soft fade, a progressive blur, a material band with a hairline, a hard edge with a shadow, a fade that starts below the pill, a background tint, or Messages' blurred bar. Changes every open chat at once.",
        default: .glassBand, code: "HomeTunables.topFadeStyle")

    /// The avatar-only list with only one conversation in it (`HomeSidebarSplitView`): off by default,
    /// so a lone Chief takes no column and the chat gets the width (visual QA 2026-10-21: one avatar in
    /// an empty band); on keeps the avatar-only column for it.
    public static let loneConversationRail = Tunable<Bool>.toggle(
        "home.loneConversationRail", section, "Avatar list for one conversation",
        help: "A narrow Home column whose list holds one conversation (only the Chief) still shows the avatar-only list beside the chat. Off gives the chat the whole width; compose stays at its top-left.",
        default: false, code: "HomeTunables.loneConversationRail")

    public static var all: [TunableDescriptor] {
        [flightRecorder.descriptor, flightRecorderCaptures.descriptor, firstRunHero.descriptor, launchIntoHome.descriptor,
         turnProgress.descriptor, richTables.descriptor, voiceInput.descriptor, chatHeader.descriptor,
         topFadeStyle.descriptor, loneConversationRail.descriptor]
    }
}

/// ``HomeTunables/turnProgress``'s choices: MessagesLab's ``HomeTurnProgressStyle``.
public nonisolated enum HomeTurnProgressChoice: String, Sendable, CaseIterable, TunableChoice {
    case narrated
    case steps
    case line

    public var tunableTitle: String {
        switch self {
        case .narrated: "Steps, thought and step now"
        case .steps: "Steps and step now"
        case .line: "One line (step now)"
        }
    }

    var style: HomeTurnProgressStyle {
        switch self {
        case .narrated: .narrated
        case .steps: .steps
        case .line: .line
        }
    }
}
