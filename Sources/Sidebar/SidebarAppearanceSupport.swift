import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Foundation
import SwiftUI
import CmuxSettings

enum SidebarMatchTerminalBackgroundSettings {
    static let userDefaultsKey = "sidebarMatchTerminalBackground"
    static let legacyAppliedSettingsFileDefaultKey = "cmux.settingsFile.sidebarMatchTerminalBackground.appliedDefault.v1"
}

enum SidebarTabItemFontScale {
    static func scale(for sidebarFontSize: CGFloat) -> CGFloat {
        GhosttyConfig.clampedSidebarFontSize(sidebarFontSize)
            / GhosttyConfig.defaultSidebarFontSize
    }
}

extension View {
    // Web-style affordance: clickable sidebar chrome shows the pointing hand.
    //
    // Prefer `.pointerStyle(.link)` on macOS 15+: it registers a proper cursor
    // rect with AppKit, so it survives the `cursorUpdate` events that the
    // overlapping portal/web/terminal views fire to reassert `NSCursor.arrow`.
    // The manual `push()`/`pop()` fallback below is used only on older systems;
    // it is easily clobbered by those reasserts (and unbalanced if the hovered
    // view is removed mid-hover), which is why it "stopped working".
    @ViewBuilder
    func cmuxPointingHandCursor() -> some View {
        if #available(macOS 15, *) {
            backport.pointerStyle(.link)
        } else {
            modifier(CmuxLegacyPointingHandCursorModifier())
        }
    }

    // Link affordance: underline the text inside a clickable sidebar control
    // while the pointer hovers it.
    func cmuxHoverUnderline() -> some View {
        modifier(CmuxHoverUnderlineModifier())
    }
}

/// Pre-macOS-15 fallback for `cmuxPointingHandCursor()`. Tracks hover state so
/// the `push()`/`pop()` pair stays balanced even if hover-exit is missed.
private struct CmuxLegacyPointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
    }
}

private struct CmuxHoverUnderlineModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .underline(isHovering)
            .onHover { isHovering = $0 }
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }
}

func coloredCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

func sidebarActiveForegroundNSColor(
    opacity: CGFloat,
    appAppearance: NSAppearance? = NSApp?.effectiveAppearance
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let baseColor: NSColor = (bestMatch == .darkAqua) ? .white : .black
    return baseColor.withAlphaComponent(clampedOpacity)
}

func titlebarControlForegroundNSColor(opacity: CGFloat) -> NSColor {
    let app = GhosttyApp.shared
    let bestMatch = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    let colorScheme: ColorScheme = bestMatch == .darkAqua ? .dark : .light
    let appearance = WindowAppearanceResolver(
        terminalAppearance: WindowTerminalAppearanceSnapshot(
            backgroundColor: app.defaultBackgroundColor,
            backgroundOpacity: app.defaultBackgroundOpacity,
            backgroundBlur: app.defaultBackgroundBlur,
            usesHostLayerBackground: app.usesHostLayerBackground
        )
    ).currentFromUserDefaults(defaults: .standard, colorScheme: colorScheme)
    return titlebarControlForegroundNSColor(
        opacity: opacity,
        appearance: appearance
    )
}

func titlebarControlForegroundNSColor(opacity: CGFloat, appearance: WindowAppearanceSnapshot) -> NSColor {
    cmuxReadableForegroundNSColor(
        on: appearance.compositedTerminalBackgroundColor,
        opacity: opacity
    )
}

func cmuxAccentNSColor(for colorScheme: ColorScheme) -> NSColor {
    switch colorScheme {
    case .dark:
        // Linear "magic blue" accent — lch(59.262% 70 291.567) ≈ #6786FF
        return NSColor(
            srgbRed: 103.0 / 255.0,
            green: 134.0 / 255.0,
            blue: 255.0 / 255.0,
            alpha: 1.0
        )
    default:
        // Linear magic blue, deepened for contrast on light — lch(47.887% 64.446 291.567) ≈ #4A6AD8
        return NSColor(
            srgbRed: 74.0 / 255.0,
            green: 106.0 / 255.0,
            blue: 216.0 / 255.0,
            alpha: 1.0
        )
    }
}

func cmuxAccentNSColor(for appAppearance: NSAppearance?) -> NSColor {
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let scheme: ColorScheme = (bestMatch == .darkAqua) ? .dark : .light
    return cmuxAccentNSColor(for: scheme)
}

func cmuxAccentNSColor() -> NSColor {
    NSColor(name: nil) { appearance in
        cmuxAccentNSColor(for: appearance)
    }
}

func cmuxAccentColor() -> Color {
    Color(nsColor: cmuxAccentNSColor())
}

/// Muted text grey — used for non-focused workspace titles and secondary
/// sidebar text so the list reads calm and recessive while staying legible.
/// Dark: Linear's #97979E. Light: a darker grey for contrast on light chrome.
enum SidebarMutedText {
    static let color = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 151.0 / 255.0, green: 151.0 / 255.0, blue: 158.0 / 255.0, alpha: 1)
            : NSColor(srgbRed: 94.0 / 255.0, green: 95.0 / 255.0, blue: 102.0 / 255.0, alpha: 1)
    })
}

/// Fixed chrome colors for the Linear-style shell, one set per scheme.
/// Light values come from Linear's light theme tokens (lch → sRGB).
enum SidebarChromeColors {
    /// Tab-bar / inactive-row surface. Dark #13141C sits below the terminal
    /// bg; light #F3F3F4 is lch(95.94% 0.5 282).
    static func tabBarBackgroundHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "#13141C" : "#F3F3F4"
    }

    /// Active (selected) tab fill. Dark #191A23 is a hair lighter than the
    /// bar; light #FCFCFD is lch(98.94% 0.5 282), Linear's light app bg.
    static func activeTabBackgroundHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "#191A23" : "#FCFCFD"
    }

    /// Active workspace-row selection block. Dark #282833; light #ECECED is
    /// lch(93.44% 0.5 282).
    static func selectedRowHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "#282833" : "#ECECED"
    }

    /// Chrome hairlines/borders (tab separators, bar↔pane divider). Dark
    /// #24252D; light #E1E1E1 is lch(89.49% 0 282) from Linear's light tokens.
    static func borderHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "#24252D" : "#E1E1E1"
    }
}

/// Renders a bundled blode-icons SVG (template imageset under
/// `Assets.xcassets/BlodeIcons`) tinted via `foregroundColor`/`foregroundStyle`.
struct BlodeIconImage: View {
    let name: String
    var size: CGFloat = 14

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

func cmuxReadableColorScheme(for backgroundColor: NSColor) -> ColorScheme {
    let backgroundLuminance = cmuxRelativeLuminance(backgroundColor)
    let whiteContrast = cmuxContrastRatio(backgroundLuminance, 1.0)
    let blackContrast = cmuxContrastRatio(backgroundLuminance, 0.0)
    return whiteContrast >= blackContrast ? .dark : .light
}

func cmuxReadableForegroundNSColor(on backgroundColor: NSColor, opacity: CGFloat) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    return cmuxReadableForegroundBaseColor(on: backgroundColor)
        .withAlphaComponent(clampedOpacity)
}

func cmuxReadableForegroundNSColor(
    preferred preferredColor: NSColor,
    on backgroundColor: NSColor,
    minimumContrast: CGFloat = 4.5
) -> NSColor {
    let foregroundForComparison = preferredColor.alphaComponent < 1
        ? cmuxCompositedNSColor(preferredColor, over: backgroundColor)
        : preferredColor
    guard cmuxContrastRatio(foreground: foregroundForComparison, background: backgroundColor) < minimumContrast else {
        return preferredColor
    }
    return cmuxReadableForegroundNSColor(on: backgroundColor, opacity: preferredColor.alphaComponent)
}

func cmuxCompositedNSColor(_ foreground: NSColor, over background: NSColor) -> NSColor {
    let fg = foreground.usingColorSpace(.sRGB) ?? foreground
    let bg = background.usingColorSpace(.sRGB) ?? background
    var foregroundRed: CGFloat = 0
    var foregroundGreen: CGFloat = 0
    var foregroundBlue: CGFloat = 0
    var foregroundAlpha: CGFloat = 0
    var backgroundRed: CGFloat = 0
    var backgroundGreen: CGFloat = 0
    var backgroundBlue: CGFloat = 0
    var backgroundAlpha: CGFloat = 0
    fg.getRed(&foregroundRed, green: &foregroundGreen, blue: &foregroundBlue, alpha: &foregroundAlpha)
    bg.getRed(&backgroundRed, green: &backgroundGreen, blue: &backgroundBlue, alpha: &backgroundAlpha)
    _ = backgroundAlpha

    let alpha = max(0, min(foregroundAlpha, 1))
    return NSColor(
        srgbRed: foregroundRed * alpha + backgroundRed * (1 - alpha),
        green: foregroundGreen * alpha + backgroundGreen * (1 - alpha),
        blue: foregroundBlue * alpha + backgroundBlue * (1 - alpha),
        alpha: 1
    )
}

func cmuxContrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
    cmuxContrastRatio(
        cmuxRelativeLuminance(foreground),
        cmuxRelativeLuminance(background)
    )
}

private func cmuxReadableForegroundBaseColor(on backgroundColor: NSColor) -> NSColor {
    cmuxReadableColorScheme(for: backgroundColor) == .dark ? .white : .black
}

private func cmuxRelativeLuminance(_ color: NSColor) -> CGFloat {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    _ = alpha

    func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }

    return 0.2126 * linearized(red)
        + 0.7152 * linearized(green)
        + 0.0722 * linearized(blue)
}

private func cmuxContrastRatio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    let lighter = max(lhs, rhs)
    let darker = min(lhs, rhs)
    return (lighter + 0.05) / (darker + 0.05)
}

struct SidebarRemoteErrorCopyEntry: Equatable {
    let workspaceTitle: String
    let target: String
    let detail: String
}

enum SidebarRemoteErrorCopySupport {
    static func menuLabel(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 {
            return String(localized: "contextMenu.copyError", defaultValue: "Copy Error")
        }
        return String(localized: "contextMenu.copyErrors", defaultValue: "Copy Errors")
    }

    static func clipboardText(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let entry = entries.first {
            return String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.single", defaultValue: "SSH error (%@): %@"),
                entry.target,
                entry.detail
            )
        }

        return entries.enumerated().map { index, entry in
            String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.item", defaultValue: "%lld. %@ (%@): %@"),
                Int64(index + 1),
                entry.workspaceTitle,
                entry.target,
                entry.detail
            )
        }.joined(separator: "\n")
    }
}

func sidebarSelectedWorkspaceBackgroundNSColor(
    for colorScheme: ColorScheme,
    sidebarSelectionColorHex: String? = UserDefaults.standard.string(forKey: "sidebarSelectionColorHex")
) -> NSColor {
    if let hex = sidebarSelectionColorHex,
       let parsed = NSColor(hex: hex) {
        return parsed
    }
    return cmuxAccentNSColor(for: colorScheme)
}

func sidebarSelectedWorkspaceForegroundNSColor(
    on backgroundColor: NSColor,
    opacity: CGFloat
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let whiteContrast = cmuxContrastRatio(foreground: .white, background: backgroundColor)
    guard whiteContrast < 2.75 else {
        return NSColor.white.withAlphaComponent(clampedOpacity)
    }
    return cmuxReadableForegroundNSColor(on: backgroundColor, opacity: clampedOpacity)
}

struct SidebarWorkspaceRowBackgroundStyle {
    let color: NSColor?
    let opacity: Double

    static let clear = Self(color: nil, opacity: 0)
}

func sidebarWorkspaceRowExplicitRailNSColor(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    customColorHex: String?,
    colorScheme: ColorScheme
) -> NSColor? {
    guard activeTabIndicatorStyle == .leftRail,
          let customColorHex else {
        return nil
    }
    return WorkspaceTabColorSettings.displayNSColor(
        hex: customColorHex,
        colorScheme: colorScheme,
        forceBright: true
    )
}

func sidebarWorkspaceRowBackgroundStyle(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    isActive: Bool,
    isMultiSelected: Bool,
    customColorHex: String?,
    colorScheme: ColorScheme,
    sidebarSelectionColorHex: String?,
    isHovered: Bool = false
) -> SidebarWorkspaceRowBackgroundStyle {
    let selectedBackground = sidebarSelectedWorkspaceBackgroundNSColor(
        for: colorScheme,
        sidebarSelectionColorHex: sidebarSelectionColorHex
    )
    let accentBackground = cmuxAccentNSColor(for: colorScheme)
    let customBackground = customColorHex.flatMap {
        WorkspaceTabColorSettings.displayNSColor(
            hex: $0,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
    }

    switch activeTabIndicatorStyle {
    case .leftRail:
        if isActive {
            // Linear selection: a solid neutral block (dark #282833, light
            // #ECECED) with scheme-native text — no accent wash.
            if let selected = NSColor(hex: SidebarChromeColors.selectedRowHex(for: colorScheme)) {
                return SidebarWorkspaceRowBackgroundStyle(color: selected, opacity: 1)
            }
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: SidebarWorkspaceListMetrics.activeSelectionFillOpacity
            )
        }
        if isMultiSelected {
            // Secondary (multi-)selection: a fainter *neutral* wash, matching
            // the neutral single-selection language (no accent tint).
            return SidebarWorkspaceRowBackgroundStyle(
                color: colorScheme == .dark ? .white : .black,
                opacity: colorScheme == .dark ? 0.07 : 0.05
            )
        }
        if isHovered {
            // Linear-style hover feedback: a whisper of overlay.
            return SidebarWorkspaceRowBackgroundStyle(
                color: colorScheme == .dark ? .white : .black,
                opacity: colorScheme == .dark ? 0.045 : 0.035
            )
        }
        // Non-focused rows (dark) sit on a flat #13141C block so the focused
        // row's fill clearly stands out; light mode stays transparent so the
        // light sidebar material shows through (Linear light rows are bare).
        if colorScheme == .dark, let base = NSColor(hex: SidebarChromeColors.tabBarBackgroundHex(for: colorScheme)) {
            return SidebarWorkspaceRowBackgroundStyle(color: base, opacity: 1)
        }
        return .clear

    case .solidFill:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if let customBackground {
            return SidebarWorkspaceRowBackgroundStyle(
                color: customBackground,
                opacity: isMultiSelected ? 0.35 : 0.7
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: 0.25)
        }
        return .clear
    }
}

// MARK: - Semantic sidebar status palette

/// Design-owned status colors so agent/CLI statuses read consistently
/// (green = running/done, accent-blue = needs input, amber = idle/waiting,
/// red = error) regardless of the ad-hoc hex a CLI may supply. Tuned calm
/// (GitHub-ish), not neon, for the dense Linear/Zed direction.
enum SidebarStatusPalette {
    static func running(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark
            ? NSColor(srgbRed: 0.36, green: 0.75, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.56, blue: 0.24, alpha: 1)
    }

    static func needsInput(_ scheme: ColorScheme) -> NSColor {
        cmuxAccentNSColor(for: scheme)
    }

    static func idle(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark
            ? NSColor(srgbRed: 0.85, green: 0.63, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.65, green: 0.44, blue: 0.04, alpha: 1)
    }

    static func done(_ scheme: ColorScheme) -> NSColor {
        // Completed work recedes (Linear-style): a muted grey dot, so green is
        // reserved exclusively for actively-running workspaces.
        scheme == .dark
            ? NSColor(srgbRed: 151.0 / 255.0, green: 151.0 / 255.0, blue: 158.0 / 255.0, alpha: 1)
            : NSColor(srgbRed: 120.0 / 255.0, green: 121.0 / 255.0, blue: 128.0 / 255.0, alpha: 1)
    }

    static func error(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark
            ? NSColor(srgbRed: 0.94, green: 0.42, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.81, green: 0.13, blue: 0.18, alpha: 1)
    }
}

/// A unified status presentation (one filled dot + semantic color) resolved
/// from an agent/CLI-supplied status key/value. Returns `nil` for values we
/// don't recognize so callers fall back to the CLI-provided icon/color.
struct SidebarStatusStyle {
    let symbolName: String
    let color: NSColor

    enum Kind {
        case running
        case needsInput
        case idle
        case done
        case error
    }

    static func kind(forKey key: String, value: String) -> Kind? {
        let haystack = "\(key) \(value)".lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { haystack.contains($0) } }
        // Order matters: more specific / higher-signal states win over the
        // generic "running" catch-all.
        if has(["error", "fail", "crash", "denied", "blocked"]) { return .error }
        if has(["need", "await", "approval", "input", "action required", "waiting for you", "your turn"]) {
            return .needsInput
        }
        if has(["done", "complete", "finished", "merged", "success", "ready"]) { return .done }
        if has(["idle", "paused", "waiting", "hibernat", "sleep", "stopped"]) { return .idle }
        if has(["running", "working", "in progress", "streaming", "thinking", "building", "active"]) {
            return .running
        }
        return nil
    }

    // Agent-supplied subtitles that just restate the status ("Claude is
    // waiting for your input") are redundant with the ranked title dot.
    static func isRedundantStatusPhrase(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let phrases = [
            "waiting for your input",
            "waiting for input",
            "needs your permission",
            "needs permission",
            "awaiting your input",
            "requires your approval",
        ]
        return phrases.contains { lowered.contains($0) }
    }

    static func resolve(key: String, value: String, colorScheme: ColorScheme) -> SidebarStatusStyle? {
        guard let kind = kind(forKey: key, value: value) else { return nil }
        return SidebarStatusStyle(symbolName: "circle.fill", color: color(for: kind, colorScheme: colorScheme))
    }

    static func color(for kind: Kind, colorScheme: ColorScheme) -> NSColor {
        switch kind {
        case .running: return SidebarStatusPalette.running(colorScheme)
        case .needsInput: return SidebarStatusPalette.needsInput(colorScheme)
        case .idle: return SidebarStatusPalette.idle(colorScheme)
        case .done: return SidebarStatusPalette.done(colorScheme)
        case .error: return SidebarStatusPalette.error(colorScheme)
        }
    }

    /// Resolves one dot color from all of a workspace's status entries, ranked
    /// by urgency so e.g. an error is never masked by a concurrent "running".
    static func rankedDotColor(
        forEntries entries: [(key: String, value: String)],
        colorScheme: ColorScheme
    ) -> NSColor? {
        let kinds = entries.compactMap { kind(forKey: $0.key, value: $0.value) }
        guard !kinds.isEmpty else { return nil }
        let priority: [Kind] = [.error, .needsInput, .running, .idle, .done]
        guard let kind = priority.first(where: { kinds.contains($0) }) else { return nil }
        return color(for: kind, colorScheme: colorScheme)
    }
}
