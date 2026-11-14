#if DEBUG
import AppKit
import CmuxNextDesignTokens
import CmuxTheme

/// Capture with `debug.hover_cards {"gallery":"transient-popover"}` (or menu,
/// tooltip, palette, toast, sheet). Each set compares the current base with
/// three material choices in light and dark. The menu and popover base already
/// uses the selected menu glass, so before and standard are intentionally equal.
/// Quieter and denser menu veils are fixtures, not production menu settings.
/// The standard tooltip keeps its shipped contrast-fitted role glass.
@MainActor
struct TransientMaterialGallery {
    enum Kind: String, CaseIterable {
        case popover, menu, tooltip, palette, toast, sheet

        var role: SurfaceRole {
            switch self {
            case .popover, .palette: .popover
            case .menu: .menu
            case .tooltip: .tooltip
            case .toast: .toast
            case .sheet: .sheet
            }
        }

        var usesMenuMaterial: Bool { self == .popover || self == .menu }

        var title: String {
            switch self {
            case .popover: "Popover"
            case .menu: "Custom menu body"
            case .tooltip: "Tooltip"
            case .palette: "Command palette"
            case .toast: "Toast"
            case .sheet: "Sheet"
            }
        }

        var sample: String {
            switch self {
            case .popover: "Open this workspace"
            case .menu: "Open in new tab     ⌘↵"
            case .tooltip: "Hide sidebar     ⌘\\"
            case .palette: "Search commands…"
            case .toast: "Changes saved"
            case .sheet: "Continue with this action?"
            }
        }

        var radius: CGFloat {
            switch self {
            case .popover, .menu: PopupStyle.standard.cornerRadius
            case .tooltip: SurfaceRole.tooltip.cornerRadius
            case .palette: Metrics.panelCornerRadius
            case .toast: SurfaceRole.toast.cornerRadius
            case .sheet: SurfaceRole.sheet.cornerRadius
            }
        }
    }

    enum Variant: String, CaseIterable {
        case before, standard, quieter, denser

        var style: FloatingGlassStyle? {
            guard self != .before else { return nil }
            var style = FloatingGlassStyle.transient
            switch self {
            case .before, .standard: break
            case .quieter:
                style.darkVeilAlpha -= 0.10
                style.lightVeilAlpha -= 0.10
            case .denser:
                style.darkVeilAlpha += 0.10
                style.lightVeilAlpha += 0.10
            }
            return style
        }

        func label(for kind: Kind) -> String {
            guard kind.usesMenuMaterial else { return rawValue }
            return switch self {
            case .before, .standard: "\(rawValue) (unchanged)"
            case .quieter, .denser: "\(rawValue) (veil fixture)"
            }
        }

        var menuVeil: CGFloat {
            switch self {
            case .before, .standard: GlassMenuMaterial.veil
            case .quieter: GlassMenuMaterial.veil - 0.10
            case .denser: GlassMenuMaterial.veil + 0.10
            }
        }
    }

    static func register() {
        for kind in Kind.allCases {
            HoverCardGallery.register("transient-\(kind.rawValue)") { cards(for: kind) }
        }
    }

    static func cards(for kind: Kind) -> [(name: String, view: NSView)] {
        let choices: [(Variant, Bool)] = [
            (.before, false), (.standard, false), (.quieter, false), (.denser, false),
            (.before, true), (.standard, true), (.quieter, true), (.denser, true),
        ]
        return choices.map { variant, isDark in
            let label = "\(kind.title) · \(variant.label(for: kind)) · \(isDark ? "dark" : "light")"
            return (name: label, view: Cell(kind: kind, variant: variant, isDark: isDark) as NSView)
        }
    }

    /// Menus and popovers use the current production menu factory for both
    /// before and standard. Only fixture variants replace its theme veil.
    /// The shipped tooltip keeps its role glass and `TooltipSurface` tint.
    static func makeSurface(kind: Kind, variant: Variant, content: NSView) -> OverlaySurfaceView {
        let radius = kind.radius
        if kind.usesMenuMaterial {
            let surface = Glass.makeMenuPanel(content: content, cornerRadius: radius)
            if variant == .quieter || variant == .denser {
                surface.contentView.subviews.compactMap { $0 as? GlassMenuVeilView }.first?.removeFromSuperview()
                let veil = MenuVeilFixture(frame: surface.contentView.bounds, alpha: variant.menuVeil)
                veil.autoresizingMask = [.width, .height]
                surface.contentView.addSubview(veil, positioned: .below, relativeTo: nil)
            }
            return surface
        }
        switch variant {
        case .before:
            if kind == .tooltip { return Glass.makeSurface(.tooltip, content: content, cornerRadius: radius, interactive: false) }
            return Glass.makeSurface(kind.role, content: content, cornerRadius: radius)
        case .standard:
            if kind == .tooltip { return Glass.makeSurface(.tooltip, content: content, cornerRadius: radius, interactive: false) }
            return Glass.makeOverlayPanel(content: content, cornerRadius: radius, tone: .neutralGlass(.transient))
        case .quieter, .denser:
            return Glass.makeOverlayPanel(content: content, cornerRadius: radius,
                                          tone: .neutralGlass(variant.style ?? .transient))
        }
    }

    /// Gallery-only veil over the real menu glass; production retains GlassMenuVeilView.
    private final class MenuVeilFixture: NSView {
        private let veilAlpha: CGFloat

        init(frame: NSRect, alpha: CGFloat) {
            veilAlpha = alpha
            super.init(frame: frame)
            wantsLayer = true
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            let glass = enclosingOverlayMaterial.map { $0 != .opaque } ?? true
            layer?.backgroundColor = glass
                ? performWithTheme { Palette.surfaceBackground.withAlphaComponent(veilAlpha) }.cgColor
                : NSColor.clear.cgColor
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class Cell: NSView {
        private let scope = ThemeScope(level: .room)
        private let surface: OverlaySurfaceView

        init(kind: Kind, variant: Variant, isDark: Bool) {
            let body = NSView()
            surface = makeSurface(kind: kind, variant: variant, content: body)
            super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 104))
            wantsLayer = true
            let input = isDark
                ? ThemeInput(background: ThemeRGB(hex: 0x1E2430), foreground: ThemeRGB(hex: 0xF1F3F7))
                : ThemeInput(background: ThemeRGB(hex: 0xF4F6FA), foreground: ThemeRGB(hex: 0x202733))
            scope.setOverride(ThemeSpec("Transient gallery \(isDark ? "dark" : "light")"), input: input, animated: false)
            scope.root(self)
            appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            // glass-opaque-allow: the fixture page behind the glass, not a floating surface.
            layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor

            let backdrop = ThemedLabel(wrappingLabelWithString: "Document text behind the material\nArtwork and color remain visible")
            backdrop.font = Typography.caption
            backdrop.ink = .tertiary
            backdrop.frame = NSRect(x: 12, y: 8, width: 236, height: 86)
            addSubview(backdrop)

            surface.frame = NSRect(x: 8, y: 25, width: 244, height: 58)
            surface.translatesAutoresizingMaskIntoConstraints = true
            addSubview(surface)

            if kind == .tooltip {
                // The real TooltipPanel adds this contrast-fitted tint between
                // its glass and text. Preserve it in the before comparison.
                let tint = NSView(frame: NSRect(x: 0, y: 0, width: 244, height: 58))
                tint.wantsLayer = true
                tint.autoresizingMask = [.width, .height]
                let tooltip = TooltipSurface(scope.tokens, lift: ChromeTunables.opaqueOverlayLift.value)
                tint.layer?.backgroundColor = tooltip.tint.nsColor.cgColor
                body.addSubview(tint)
            }

            let text = ThemedLabel(labelWithString: kind.sample)
            text.font = kind == .tooltip ? Typography.caption : Typography.body
            text.frame = NSRect(x: 12, y: 17, width: 220, height: 24)
            if kind == .tooltip {
                let tooltip = TooltipSurface(scope.tokens, lift: ChromeTunables.opaqueOverlayLift.value)
                text.themeColor = { tooltip.ink.nsColor }
            }
            body.addSubview(text)

            if kind == .menu {
                let note = ThemedLabel(labelWithString: "Custom menu body; system NSMenu unchanged")
                note.font = Typography.caption
                note.ink = .secondary
                note.frame = NSRect(x: 12, y: 85, width: 236, height: 16)
                addSubview(note)
            }
            surface.applyTheme()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 104) }
    }
}
#endif
