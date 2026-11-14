public import CmuxNextDesignTokens

/// The toast tuning tool's knobs (Debug Settings > Toasts, DEV and NIGHTLY; Lawrence 2026-11-12: "so we can
/// refine the toasts"): how long toasts show, their glass, padding and motion. Palette "Debug: Toast Tuning"
/// opens this section beside live sample toasts that redraw as a knob moves (`debug.toastTuning`). Release
/// and RC never activate the store, so they keep these defaults. Labels are English developer text, as for
/// every Debug Settings section (`TunableSection`).
///
/// To keep a tuned look: Debug Settings' "Copy changed values as JSON", then bake the values in as these
/// defaults (``CmuxToastTuning`` reads them all).
public nonisolated struct CmuxToastTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "toasts", title: "Toasts", symbol: "text.bubble", order: 13)

    public static let durationScale = Tunable<Double>.number(
        "toast.durationScale", section, "Duration scale",
        help: "Each toast shows for its asked time times this (Lawrence 2026-11-12: show toasts longer). Toasts that echo a live change (zoom percent, density) keep their exact time.",
        default: 2, range: 1...5, step: 0.25, unit: .multiplier, code: "CmuxToastTunables.durationScale")
    public static let minimumSeconds = Tunable<Double>.number(
        "toast.minimumSeconds", section, "Shortest time",
        help: "No toast that ends on its own shows for less, after the scale.",
        default: 6, range: 1...30, step: 0.5, unit: .seconds, code: "CmuxToastTunables.minimumSeconds")
    public static let glass = Tunable<CmuxToastGlass>.choice(
        "toast.glass", section, "Glass",
        help: "The glass gallery look the toasts draw on. Reduce Transparency keeps the opaque surface.",
        default: .liquidVeil, code: "CmuxToastTunables.glass")
    public static let horizontalPadding = Tunable<Double>.number(
        "toast.horizontalPadding", section, "Leading padding",
        help: "Room between the toast's leading edge and its message.",
        default: 12, range: 4...32, step: 1, unit: .points, code: "CmuxToastTunables.horizontalPadding")
    public static let trailingPadding = Tunable<Double>.number(
        "toast.trailingPadding", section, "Trailing padding",
        help: "Room between the close button and the toast's trailing edge.",
        default: 8, range: 2...32, step: 1, unit: .points, code: "CmuxToastTunables.trailingPadding")
    public static let verticalPadding = Tunable<Double>.number(
        "toast.verticalPadding", section, "Vertical padding",
        help: "Room above and below the toast's row.",
        default: 8, range: 2...24, step: 1, unit: .points, code: "CmuxToastTunables.verticalPadding")
    public static let buttonSpacing = Tunable<Double>.number(
        "toast.buttonSpacing", section, "Button spacing",
        help: "Room between the toast's buttons (Don't Show Again, close).",
        default: 4, range: 0...20, step: 1, unit: .points, code: "CmuxToastTunables.buttonSpacing")
    public static let messageWidth = Tunable<Double>.number(
        "toast.messageWidth", section, "Message width",
        help: "The widest a message runs before it wraps.",
        default: 360, range: 200...640, step: 10, unit: .points, code: "CmuxToastTunables.messageWidth")
    public static let rise = Tunable<Double>.number(
        "toast.rise", section, "Rise",
        help: "How far below its slot a new toast starts as it fades in. 0: it only fades.",
        default: 8, range: 0...40, step: 1, unit: .points, code: "CmuxToastTunables.rise")

    public static let playgroundFocus = Tunable<CmuxToastPlaygroundFocus>.choice(
        "toast.playgroundFocus", section, "Playground shows",
        help: "Every style in the Toast Playground, or one alone. Applies the next time the playground opens.",
        default: .all, code: "CmuxToastTunables.playgroundFocus")

    public static var all: [TunableDescriptor] {
        [durationScale.descriptor, minimumSeconds.descriptor, glass.descriptor, horizontalPadding.descriptor, trailingPadding.descriptor,
         verticalPadding.descriptor, buttonSpacing.descriptor, messageWidth.descriptor, rise.descriptor, playgroundFocus.descriptor]
    }
}
