import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// cx-ujp: a cmux dialog in a light theme drew low-contrast text. The overlay page draws the dialog
/// card now (``CmuxDialogView``); these guard the button looks every native card
/// (`CmuxDialogButtonView`) still draws: each ink reads on the card, light and dark, and a focused
/// button's ring sits outside its fill, unclipped, at 3:1.
@MainActor @Suite(.serialized, .closesItsWindows) struct CmuxDialogLightContrastTests {
    private static let light = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F))
    private static let dark = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6))

    private static func scope(_ input: ThemeInput, _ name: String) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        return scope
    }

    /// An inactive window rooted in `scope`.
    private static func window(in scope: ThemeScope) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scope.root(try #require(window.contentView))
        return window
    }

    /// The same contract over the glass card (the veil over the scrimmed window, as a dialog shows
    /// without Reduce Transparency), for both destructive variants, in each state, light and dark,
    /// for a theme with its own accent too.
    @Test(arguments: [false, true])
    func everyDialogButtonInkReadsOnTheGlassCard(filledDestructive: Bool) throws {
        let accented = ThemeInput(background: ThemeRGB(hex: 0x1F2430), foreground: ThemeRGB(hex: 0xCBCCC6))
        for input in [Self.light, Self.dark, accented] {
            let tokens = ThemeTokens.derive(from: input)
            for role in [CmuxDialogButton.Role.default, .destructive, .cancel, .normal] {
                for state in CmuxDialogButtonLook.State.allCases {
                    let look = CmuxDialogButtonLook(role: role, tokens: tokens, state: state, filledDestructive: filledDestructive)
                    #expect(look.surfaces.count == CmuxDialogButtonLook.cardSurfaces(tokens).count)
                    for surface in look.surfaces {
                        #expect(look.title.contrast(with: surface) >= 4.5, "\(role) \(state) title: \(look.title.contrast(with: surface)):1")
                        #expect(look.keyHint.contrast(with: surface) >= 4.5, "\(role) \(state) hint: \(look.keyHint.contrast(with: surface)):1")
                    }
                }
            }
            // A filled destructive button and the default one are solid: what shows through the glass
            // cannot lower their contrast.
            #expect(CmuxDialogButtonLook(role: .default, tokens: tokens).fill.alpha == 1)
            #expect(CmuxDialogButtonLook(role: .destructive, tokens: tokens, filledDestructive: true).fill.alpha == 1)
        }
    }

    /// The keyboard focus shows on a solid default button too: the ring sits just outside the fill,
    /// in its window, and nothing clips it (a ring drawn inside a solid fill, or clipped away, left
    /// the focused button looking like any other).
    @Test func theFocusedButtonDrawsAnUnclippedRingOutsideItsFill() throws {
        let scope = try Self.scope(Self.dark, "Focus Ring")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let save = try Self.button(in: window)
        #expect(window.makeFirstResponder(save))
        save.layoutSubtreeIfNeeded()
        let layer = try #require(save.layer)
        #expect(!save.clipsToBounds && !layer.masksToBounds, "the ring is clipped away")
        // The ring is the bordered layer outside the button (the gap line on a solid fill is inside).
        let rings = (layer.sublayers ?? []).filter { !$0.isHidden && $0.borderWidth > 0 }
        let ring = try #require(rings.max { $0.frame.width < $1.frame.width }, "a focused button draws no ring")
        #expect(ring.frame.width > layer.bounds.width && ring.frame.height > layer.bounds.height, "the ring is inside the fill")
        #expect(window.makeFirstResponder(nil))
        #expect((layer.sublayers ?? []).allSatisfy { $0.isHidden || $0.borderWidth == 0 }, "an unfocused button keeps its ring")
    }

    /// Visual review of #27638: a focused solid button drew its focus band inside its bounds, so its
    /// fill looked 3 px smaller on every side than its unfocused neighbors' and its edges no longer
    /// lined up with theirs. Every focus layer of a focused button sits outside its fill.
    @Test func aFocusedSolidButtonKeepsItsFullFill() throws {
        let scope = try Self.scope(Self.dark, "Focus Full Fill")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let save = try Self.button(in: window)
        #expect(window.makeFirstResponder(save))
        save.layoutSubtreeIfNeeded()
        let layer = try #require(save.layer)
        let shown = (layer.sublayers ?? []).filter { !$0.isHidden && $0.borderWidth > 0 }
        #expect(shown.count >= 2, "a focused solid button draws its gap and its ring")
        for band in shown {
            // A border is drawn inside its layer's frame: it is outside the fill only if the frame's
            // inner edge (frame inset by the border) still contains the button's bounds.
            let inner = band.frame.insetBy(dx: band.borderWidth, dy: band.borderWidth)
            #expect(inner.contains(layer.bounds), "a focus band \(band.frame) (\(band.borderWidth) pt) covers the fill \(layer.bounds)")
        }
    }

    /// Visual review of #27638 (real-app capture at c45470c72c22): the light-mode focus ring read
    /// 2.73:1 on the dialog card, under WCAG's 3:1 for a focus indicator, and on a gray Cancel it is
    /// the only sign of focus. The ring is fit to 3:1 on both card surfaces, light and dark.
    @Test(arguments: [false, true])
    func theFocusRingReadsAtThreeToOneOnTheCard(isDark: Bool) throws {
        let tokens = ThemeTokens.derive(from: isDark ? Self.dark : Self.light)
        let look = CmuxDialogButtonLook(role: .cancel, tokens: tokens)
        // The real glass card shows little of its veil: on a light theme it measured rgb(223,223,223),
        // the scrimmed window itself (real-app capture at 1dcfb3faa718, where a ring fit only to the
        // veil estimate still read 2.66:1). The ring reads on that too.
        let scrimmedWindow = tokens.scrim.composited(over: tokens.windowBackground.withAlpha(1))
        for surface in CmuxDialogButtonLook.cardSurfaces(tokens) + [scrimmedWindow] {
            let ring = look.focusRing.composited(over: surface)
            #expect(ring.contrast(with: surface) >= 3, "ring \(ring.contrast(with: surface)):1 on the card")
        }
    }

    /// The default button of a native card ("Choose File"), alone in `window`.
    private static func button(in window: NSWindow) throws -> CmuxDialogButtonView {
        let root = try #require(window.contentView)
        let button = CmuxDialogButtonView(.ok("Choose File"), hint: .return, target: nil, action: NSSelectorFromString("noop:"))
        button.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(button)
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
                                     button.topAnchor.constraint(equalTo: root.topAnchor, constant: 40)])
        root.layoutSubtreeIfNeeded()
        return button
    }
}
