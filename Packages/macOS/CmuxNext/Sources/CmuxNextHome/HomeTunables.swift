public import CmuxNextDesign

/// Debug Settings of the Home transcript (DEV and NIGHTLY only; Release and
/// RC never activate the store, so they keep the defaults, which are off in
/// every Release compile).
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

    public static var all: [TunableDescriptor] { [flightRecorder.descriptor, flightRecorderCaptures.descriptor] }
}
