public import CmuxNextDesign
import MessagesLabHome

/// Debug Settings of the Home transcript (DEV and NIGHTLY only; Release and
/// RC never activate the store, so they keep the defaults: the flight
/// recorder's are off; product defaults such as `firstRunHero` are on, and
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

    /// The Chief's running indicator above its typing dots (`HomeTurnProgress`): the folded steps, the
    /// Chief's newest thought and the step running now (default, Leo 2026-10-20), or the one line before.
    public static let turnProgress = Tunable<HomeTurnProgressChoice>.choice(
        "home.turnProgress", section, "Chief running indicator",
        help: "While the Chief works: its finished steps folded into one row (\"Ran 3 commands ›\"), its newest thought, and the step running now. Steps leaves out the thought; One line is the step running now only.",
        default: .narrated, code: "HomeTunables.turnProgress")

    public static var all: [TunableDescriptor] {
        [flightRecorder.descriptor, flightRecorderCaptures.descriptor, firstRunHero.descriptor, turnProgress.descriptor]
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
