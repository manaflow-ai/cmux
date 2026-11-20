public import CoreGraphics
public import CmuxNextDesignTokens

/// The corner of every popup, menu, popover and hover card, native and web (Leo 2026-11-20: "the little
/// curvature, border radius. I don't even know how you guys came up with it"). The Debug Settings choice
/// `glass.popupCorner` (DEV and NIGHTLY) keeps the three gallery variants reachable so they can be compared
/// live; Release draws the default. schemas/design-scale/design-scale.json `namedRadii.popup` is the
/// default's number (`DesignTokens.radiusPopup`); the host hands the page the same value as
/// `--cmux-popup-radius` (``cssVariables``), so a web popup and a native one change together.
public nonisolated enum PopupCornerLook: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// 8: the pane radius popups took until 2026-11-20 (99d72e1, #24589).
    case pane
    /// 12: between the two.
    case soft
    /// 18: a popular macOS launcher's popover corner (the default).
    case reference

    public var tunableTitle: String {
        switch self {
        case .pane: "8 pt (the pane corner, before)"
        case .soft: "12 pt"
        case .reference: "18 pt (the reference launcher's)"
        }
    }

    /// The corner in points, before the interface scale.
    public var points: CGFloat {
        switch self {
        case .pane: 8
        case .soft: 12
        case .reference: DesignTokens.radiusPopup
        }
    }

    /// Debug Settings > Glass and Overlays > Popup corner.
    public static let tunable = Tunable<PopupCornerLook>.choice(
        "glass.popupCorner", .glass, "Popup corner",
        help: "Corner radius of every popup, menu, popover and hover card, native and web. A row inside stays concentric (the corner less the popup's padding). Default 18.",
        default: .reference, code: "PopupCornerLook.tunable")

    /// The variant in effect.
    public static var current: PopupCornerLook { tunable.value }
}

/// The corner and padding of every dialog, native (`CmuxDialogView`) and web (`.ui-dialog.ui-glass`): the
/// button corner plus one padding (Lawrence 2026-11-15: "all dialogs needs concentric padding with buttons
/// inside"). The Debug Settings choice `glass.dialogCorner` keeps the gallery variants reachable; the
/// default's padding is design-scale.json `dialog.padding` (`DesignTokens.dialogPadding`), which the page
/// reads as `--ds-dialog-padding` and the host overrides with `--cmux-dialog-padding` (``cssVariables``).
public nonisolated enum DialogCornerLook: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// Padding 12 on both sides: an 8 button corner + 12 = 20, a popular macOS launcher's dialog (the default).
    case reference
    /// Padding 16 on both sides: 8 + 16 = 24, today's native dialog on the web too.
    case round
    /// Today's split, before 2026-11-20: native 16 (a 24 corner), web 24 (a 32 corner).
    case split

    public var tunableTitle: String {
        switch self {
        case .reference: "20 pt (padding 12, the reference launcher's)"
        case .round: "24 pt (padding 16)"
        case .split: "Native 24 / web 32 (before)"
        }
    }

    /// The native card's padding in points, before the text size.
    public var nativePadding: CGFloat {
        switch self {
        case .reference: DesignTokens.dialogPadding
        case .round, .split: 16
        }
    }

    /// The web dialog's padding in px: the native one, but for `split`.
    public var webPadding: CGFloat {
        switch self {
        case .reference, .round: nativePadding
        case .split: 24
        }
    }

    /// Debug Settings > Glass and Overlays > Dialog corner.
    public static let tunable = Tunable<DialogCornerLook>.choice(
        "glass.dialogCorner", .glass, "Dialog corner",
        help: "A dialog's padding, native and web; its corner is the button corner plus it. Default 20 (padding 12).",
        default: .reference, code: "DialogCornerLook.tunable")

    /// The variant in effect.
    public static var current: DialogCornerLook { tunable.value }
}

/// The page's copy of the two corner looks (`WebTheme.variables`).
public nonisolated struct SurfaceCornerLooks: Sendable, Equatable {
    public var popup: PopupCornerLook
    public var dialog: DialogCornerLook

    public init(popup: PopupCornerLook, dialog: DialogCornerLook) {
        self.popup = popup
        self.dialog = dialog
    }

    /// The looks in effect.
    public static var current: SurfaceCornerLooks { SurfaceCornerLooks(popup: .current, dialog: .current) }

    /// `--cmux-popup-radius` (the native popup corner, which a corner radius the person set still wins) and
    /// `--cmux-dialog-padding`, in CSS px at `pageZoom`, so the page draws the same points as the App.
    @MainActor public func cssVariables(pageZoom: CGFloat) -> [String: String] {
        let zoom = max(pageZoom, 0.01)
        return [
            "--cmux-popup-radius": SidebarCardMetrics.px(PopupStyle.cornerRadius(for: popup) / zoom),
            "--cmux-dialog-padding": SidebarCardMetrics.px(dialog.webPadding),
        ]
    }

    /// The Debug choices' descriptors (`DesignTunables.all`).
    public static var tunables: [TunableDescriptor] { [PopupCornerLook.tunable.descriptor, DialogCornerLook.tunable.descriptor] }
}
