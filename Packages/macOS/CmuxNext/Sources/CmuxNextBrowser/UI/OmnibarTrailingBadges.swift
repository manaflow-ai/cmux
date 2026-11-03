import AppKit

/// The omnibar's trailing badges (browser focus mode, browser profile, machine, bookmark star), made
/// the first time one shows. A new pane's first frame shows none of them: making all four in its key
/// turn was a quarter of `AddressBarView.init` (#32909, Shift-Cmd-L). The handlers the App sets
/// before then are kept here and given to the views when they are made.
@MainActor
final class OmnibarTrailingBadges {
    private(set) var stackIfMade: NSStackView?
    private(set) var focusModeIfMade: FocusModeBadgeView?
    private(set) var profileIfMade: ProfileBadgeView?
    private(set) var machineIfMade: MachineBadgeView?
    private(set) var starIfMade: BookmarkStarButton?

    var onFocusModePress: (() -> Void)? { didSet { focusModeIfMade?.onPress = onFocusModePress } }
    var machineMenu: (() -> NSMenu?)? { didSet { machineIfMade?.makeMenu = machineMenu } }
    var profileMenu: (() -> NSMenu?)? { didSet { profileIfMade?.makeMenu = profileMenu } }
    var onStar: ((NSView) -> Void)? { didSet { starIfMade?.onPress = onStar } }
    /// Adds the stack, once made, to the bar and places it.
    private let install: (NSStackView) -> Void

    init(install: @escaping (NSStackView) -> Void) {
        self.install = install
    }

    /// Whether any badge shows (the field ends at the badges instead of the bar's end).
    var anyShown: Bool { stackIfMade?.arrangedSubviews.contains { !$0.isHidden } ?? false }

    /// The four badges, hidden, in their stack in the bar: made on the first call.
    @discardableResult
    func make() -> NSStackView {
        if let stackIfMade { return stackIfMade }
        let focusMode = FocusModeBadgeView(), profile = ProfileBadgeView(), machine = MachineBadgeView(), star = BookmarkStarButton()
        for view in [focusMode, profile, machine, star] as [NSView] { view.isHidden = true }
        focusMode.onPress = onFocusModePress
        profile.makeMenu = profileMenu
        machine.makeMenu = machineMenu
        star.onPress = onStar
        let stack = NSStackView(views: [focusMode, profile, machine, star])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        (focusModeIfMade, profileIfMade, machineIfMade, starIfMade, stackIfMade) = (focusMode, profile, machine, star, stack)
        install(stack)
        return stack
    }

    var focusMode: FocusModeBadgeView { make(); return focusModeIfMade ?? FocusModeBadgeView() }
    var profile: ProfileBadgeView { make(); return profileIfMade ?? ProfileBadgeView() }
    var machine: MachineBadgeView { make(); return machineIfMade ?? MachineBadgeView() }
    var star: BookmarkStarButton { make(); return starIfMade ?? BookmarkStarButton() }
}
