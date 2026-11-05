public import CmuxNextCloud
public import CmuxNextDesign
public import AppKit
public import Foundation

/// The one card a Cloud create at the plan's cap shows when nothing can be paused for it (``CloudMachineCap``,
/// leo-workspace design/cloud.md "At the machine cap"): a Pause button for each of the person's busy machines (the
/// newest few, each with its last activity on a line), Upgrade, and Run on This Mac. A free plan: Upgrade and Run on
/// This Mac. Its text is in Resources/Cloud.xcstrings with every app locale.
public nonisolated struct CloudMachineCapCard {
    public nonisolated init() {}
    public static let identifier = "cmux.dialog.cloud.atCap"
    /// At most this many Pause buttons; the card lists no more machines than it offers to pause.
    public static let pauseButtons = 3
    static let pausePrefix = "pause:"

    /// The card for `cap`; `now` dates each machine's last activity. `freePlanDetail`: the app's upgrade card text
    /// (its plans and prices), which a free plan's card keeps.
    public static func spec(_ cap: CloudMachineCap, now: Date = Date(), freePlanDetail: String? = nil) -> CmuxDialogSpec {
        let shown = cap.freePlan ? [] : Array(cap.busy.prefix(pauseButtons))
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        let lines = shown.map { busy in
            busy.lastActiveAt.map { Strings.busyLine(busy.name, active: relative.localizedString(for: $0, relativeTo: now)) } ?? busy.name
        }
        let detail = cap.freePlan ? freePlanDetail ?? Strings.freePlanDetail : shown.isEmpty ? Strings.atCapNoneDetail : Strings.atCapDetail
        let pauses = shown.map { CmuxDialogButton(id: pausePrefix + $0.machine, title: Strings.pause($0.name), role: .normal) }
        return CmuxDialogSpec(
            title: cap.freePlan ? Strings.freePlanTitle : Strings.atCapTitle, lines: [detail] + lines,
            buttons: [.cancel(Strings.notNow)] + pauses + [
                CmuxDialogButton(id: "runHere", title: Strings.runHere, role: .normal),
                CmuxDialogButton(id: "upgrade", title: Strings.upgrade, role: .default),
            ],
            identifier: identifier)
    }

    /// Shows the card on `window` and answers the person's pick; Upgrade also runs `openPricing`. No window: nil.
    @MainActor public static func choose(_ cap: CloudMachineCap, in window: NSWindow?, freePlanDetail: String? = nil,
                                         openPricing: @MainActor () -> Void) async -> CloudMachineCap.Choice? {
        guard let window else { return nil }
        let picked = choice(await CmuxDialogCenter.shared.present(spec(cap, freePlanDetail: freePlanDetail), in: .window(window)))
        if picked == .upgrade { openPricing() }
        return picked
    }

    /// The choice the card's `answer` names; nil for Not now, Escape or a dismissal.
    public static func choice(_ answer: CmuxDialogAnswer?) -> CloudMachineCap.Choice? {
        guard let answer, !answer.isDismissal else { return nil }
        if answer.button.hasPrefix(pausePrefix) { return .pause(String(answer.button.dropFirst(pausePrefix.count))) }
        return switch answer.button {
        case "upgrade": .upgrade
        case "runHere": .runHere
        default: nil
        }
    }

    /// The one line said after cmux paused `name` (the workspace's, else the machine's) to make room.
    public static func madeRoom(_ name: String) -> String { Strings.madeRoom(name) }

    enum Strings {
        static var atCapTitle: String {
            String(localized: "cloud.atCap.title", defaultValue: "All your Cloud machines are busy", table: "Cloud", bundle: .module)
        }
        static var atCapDetail: String {
            String(localized: "cloud.atCap.detail", defaultValue: "Your plan's running machines are all in use. Pause one to make room, upgrade for more, or run this on your Mac.",
                   table: "Cloud", bundle: .module)
        }
        static var atCapNoneDetail: String {
            String(localized: "cloud.atCap.detailNoneYours", defaultValue: "Your team's running machines are all in use. Upgrade for more, or run this on your Mac.",
                   table: "Cloud", bundle: .module)
        }
        static var freePlanTitle: String {
            String(localized: "cloud.atCap.freeTitle", defaultValue: "Cloud machines need a paid plan", table: "Cloud", bundle: .module)
        }
        static var freePlanDetail: String {
            String(localized: "cloud.atCap.freeDetail", defaultValue: "Your plan has no Cloud machines. Upgrade, or run this on your Mac.", table: "Cloud", bundle: .module)
        }
        static func busyLine(_ name: String, active: String) -> String {
            String(format: String(localized: "cloud.atCap.busyLine", defaultValue: "%1$@: last active %2$@", table: "Cloud", bundle: .module), name, active)
        }
        static func pause(_ name: String) -> String {
            String(format: String(localized: "cloud.atCap.pause", defaultValue: "Pause %@", table: "Cloud", bundle: .module), name)
        }
        static var upgrade: String { String(localized: "cloud.atCap.upgrade", defaultValue: "Upgrade", table: "Cloud", bundle: .module) }
        static var runHere: String { String(localized: "cloud.atCap.runHere", defaultValue: "Run on This Mac", table: "Cloud", bundle: .module) }
        static var notNow: String { String(localized: "cloud.atCap.notNow", defaultValue: "Not Now", table: "Cloud", bundle: .module) }
        static func madeRoom(_ name: String) -> String {
            String(format: String(localized: "cloud.atCap.madeRoom", defaultValue: "Paused %@'s machine to make room", table: "Cloud", bundle: .module), name)
        }
    }
}
