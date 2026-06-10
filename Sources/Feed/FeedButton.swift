import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

/// Single DRY button primitive used across every actionable card
/// (permission / plan / question / filter pills / option pills).
/// Replaces the old PermissionCTAButton / PlanCTAButton /
/// FeedPillButton trio so styling is defined in exactly one place.
struct FeedButton: View {
    enum Kind: String {
        /// Transparent pill that lights up on hover/selection. Used
        /// for filter bar pills and single-select option pills.
        case ghost
        /// Soft neutral fill (e.g. Manual, disabled Submit).
        case soft
        /// Dark background with white text (Deny).
        case dark
        /// Light background with black text (Allow Once).
        case light
        /// Solid blue (Always Allow, Send feedback, active Submit).
        case primary
        /// Solid green (Auto, checked multi-select option, confirmations).
        case success
        /// Solid orange (warning actions).
        case warning
        /// Solid red (destructive deny).
        case destructive
    }

    enum Size {
        case compact  // filter bar / option pills
        case medium   // full-width CTAs
    }

    let label: String
    var leadingIcon: String? = nil
    var trailingIcon: String? = nil
    var kind: Kind = .ghost
    var size: Size = .compact
    var fullWidth: Bool = false
    var isSelected: Bool = false
    var dimmed: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered: Bool = false
#if DEBUG
    @AppStorage(FeedButtonDebugSettings.generationKey) private var debugStyleGeneration = 0
#endif

    var body: some View {
#if DEBUG
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesSystemGlassButtonStyle {
            systemGlassButton
        } else {
            plainFeedButton
        }
        #else
        plainFeedButton
        #endif
#else
        plainFeedButton
#endif
    }

    private var plainFeedButton: some View {
        Button {
            performAction()
        } label: {
            labelContent
            .foregroundColor(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(buttonBackground)
            .overlay(buttonBorder)
            .shadow(
                color: buttonShadowColor,
                radius: buttonShadowRadius,
                x: 0,
                y: buttonShadowY
            )
            .opacity(dimmed ? 0.55 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            handleHover(hovering)
        }
        .help(label)
    }

    private var labelContent: some View {
        HStack(spacing: iconSpacing) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
                    .font(.system(size: iconSize, weight: .semibold))
            }
            Text(label)
                .font(.system(size: labelSize, weight: .semibold))
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: iconSize, weight: .semibold))
            }
        }
    }

    private var standardLabelContent: some View {
        HStack(spacing: 4) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
            }
            Text(label)
            if let trailingIcon {
                Image(systemName: trailingIcon)
            }
        }
        .font(.system(size: labelSize, weight: .semibold))
    }

    private func performAction() {
        // `dimmed` doubles as the disabled signal — swallow the
        // click at the primitive so upstream action closures don't
        // have to re-check.
        guard !dimmed else { return }
        action()
    }

    private func handleHover(_ hovering: Bool) {
        isHovered = hovering
        // Only swap the cursor when the button is disabled —
        // enabled buttons keep the default arrow so the Feed
        // feels like the rest of the app. Pop on mouseout so a
        // stale "not allowed" cursor doesn't stick.
        if dimmed, hovering {
            NSCursor.operationNotAllowed.push()
        } else if dimmed, !hovering {
            NSCursor.pop()
        }
    }

#if DEBUG
    private var usesSystemGlassButtonStyle: Bool {
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .standardGlass, .standardTintedGlass, .nativeGlass, .nativeProminentGlass, .commandLight:
            return true
        case .solid, .glass, .liquid, .halo, .command, .outline, .flat:
            return false
        }
    }

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        @ViewBuilder
        private var systemGlassButton: some View {
            if FeedButtonDebugSettings.visualStyle == .standardGlass {
                standardSystemGlassButtonBase
                    .buttonStyle(.glass)
            } else if FeedButtonDebugSettings.visualStyle == .standardTintedGlass {
                standardSystemGlassButtonBase
                    .buttonStyle(.glass)
                    .tint(systemGlassTint)
            } else if FeedButtonDebugSettings.visualStyle == .nativeProminentGlass {
                systemGlassButtonBase
                    .buttonStyle(.glassProminent)
            } else {
                systemGlassButtonBase
                    .buttonStyle(.glass)
            }
        }

        @available(macOS 26.0, *)
        private var standardSystemGlassButtonBase: some View {
            Button {
                performAction()
            } label: {
                standardLabelContent
                    .frame(maxWidth: fullWidth ? .infinity : nil)
            }
            .controlSize(size == .compact ? .small : .regular)
            .disabled(dimmed)
            .opacity(dimmed ? 0.55 : 1.0)
            .onHover { hovering in
                handleHover(hovering)
            }
            .help(label)
        }

        @available(macOS 26.0, *)
        private var systemGlassButtonBase: some View {
            Button {
                performAction()
            } label: {
                labelContent
                    .foregroundStyle(systemGlassForeground)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                    .padding(.horizontal, max(CGFloat(0), horizontalPadding - 2))
                    .padding(.vertical, max(CGFloat(0), verticalPadding - 1))
                    .contentShape(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
            .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
            .controlSize(size == .compact ? .small : .regular)
            .tint(systemGlassTint)
            .disabled(dimmed)
            .opacity(dimmed ? 0.55 : 1.0)
            .onHover { hovering in
                handleHover(hovering)
            }
            .help(label)
        }
    #endif

    private var systemGlassTint: Color {
        glassEffectTint.opacity(FeedButtonDebugSettings.glassTintOpacity)
    }

    private var systemGlassForeground: Color {
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: .foreground,
            colorScheme: colorScheme
        ) {
            return color
        }

        switch FeedButtonDebugSettings.visualStyle {
        case .nativeProminentGlass:
            return kind == .light ? .black : .white
        case .nativeGlass:
            return .primary
        case .standardGlass, .standardTintedGlass, .solid, .glass, .liquid, .halo, .command, .commandLight, .outline, .flat:
            return foreground
        }
    }
#endif

    // MARK: - Style resolution

    private var labelSize: CGFloat { size == .compact ? 10 : 10.5 }
    private var iconSize: CGFloat { size == .compact ? 9 : 10 }
    private var iconSpacing: CGFloat { size == .compact ? 3 : 5 }
    private var cornerRadius: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        return size == .compact
            ? CGFloat(FeedButtonDebugSettings.compactCornerRadius)
            : CGFloat(FeedButtonDebugSettings.mediumCornerRadius)
#else
        return size == .compact ? 5 : 6
#endif
    }
    private var horizontalPadding: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        return size == .compact
            ? CGFloat(FeedButtonDebugSettings.compactHorizontalPadding)
            : CGFloat(FeedButtonDebugSettings.mediumHorizontalPadding)
#else
        return size == .compact ? 8 : 12
#endif
    }
    private var verticalPadding: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        return size == .compact
            ? CGFloat(FeedButtonDebugSettings.compactVerticalPadding)
            : CGFloat(FeedButtonDebugSettings.mediumVerticalPadding)
#else
        return size == .compact ? 4 : 5
#endif
    }

    private var foreground: Color {
#if DEBUG
        _ = debugStyleGeneration
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: .foreground,
            colorScheme: colorScheme
        ) {
            return color
        }
#endif
        switch kind {
        case .ghost:
            return isSelected ? .primary : .primary.opacity(0.85)
        case .soft: return .primary
        case .dark: return .white
        case .light: return .black
        case .primary: return .white
        case .success: return .white
        case .warning: return .white
        case .destructive: return .white
        }
    }

    private var backgroundFill: Color {
#if DEBUG
        _ = debugStyleGeneration
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: isHovered ? .hoverBackground : .background,
            colorScheme: colorScheme
        ) {
            return color
        }
#endif
        switch kind {
        case .ghost:
            if isSelected { return Color.primary.opacity(0.12) }
            if isHovered { return Color.primary.opacity(0.06) }
            return Color.clear
        case .soft:
            return isHovered ? Color.primary.opacity(0.16) : Color.primary.opacity(0.10)
        case .dark:
            return isHovered ? Color.black.opacity(0.85) : Color.black.opacity(0.75)
        case .light:
            return isHovered ? Color.white.opacity(0.96) : Color.white.opacity(0.88)
        case .primary:
            return isHovered
                ? Color(red: 0.28, green: 0.55, blue: 0.95)
                : Color(red: 0.24, green: 0.48, blue: 0.88)
        case .success:
            return isHovered
                ? Color(red: 0.22, green: 0.72, blue: 0.42)
                : Color(red: 0.18, green: 0.62, blue: 0.35)
        case .warning:
            return isHovered
                ? Color(red: 0.95, green: 0.55, blue: 0.18)
                : Color(red: 0.92, green: 0.54, blue: 0.29)
        case .destructive:
            return isHovered
                ? Color(red: 0.85, green: 0.28, blue: 0.28)
                : Color(red: 0.75, green: 0.22, blue: 0.22)
        }
    }

#if DEBUG
    private var glassEffectTint: Color {
        _ = debugStyleGeneration
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: isHovered ? .hoverBackground : .background,
            colorScheme: colorScheme
        ) {
            return color
        }

        switch kind {
        case .ghost: return Color.accentColor
        case .soft: return Color.gray
        case .dark: return Color.black
        case .light: return Color.white
        case .primary: return Color(red: 0.24, green: 0.48, blue: 0.88)
        case .success: return Color(red: 0.18, green: 0.62, blue: 0.35)
        case .warning: return Color(red: 0.92, green: 0.54, blue: 0.29)
        case .destructive: return Color(red: 0.75, green: 0.22, blue: 0.22)
        }
    }
#endif

    @ViewBuilder
    private var buttonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
#if DEBUG
        let generation = debugStyleGeneration
        switch generation >= 0 ? FeedButtonDebugSettings.visualStyle : .solid {
        case .solid:
            shape.fill(backgroundFill)
        case .standardGlass:
            shape.fill(.regularMaterial)
        case .standardTintedGlass:
            shape
                .fill(.regularMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .glass:
            shape
                .fill(.thinMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .nativeGlass:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(
                        .regular
                            .tint(glassEffectTint.opacity(FeedButtonDebugSettings.glassTintOpacity))
                            .interactive(!dimmed),
                        in: shape
                    )
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(backgroundFill.opacity(0.20)))
            }
            #else
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(backgroundFill.opacity(0.20)))
            #endif
        case .nativeProminentGlass:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(
                        .regular
                            .tint(glassEffectTint.opacity(FeedButtonDebugSettings.glassTintOpacity))
                            .interactive(!dimmed),
                        in: shape
                    )
                    .overlay(
                        shape.fill(
                            backgroundFill.opacity(isHovered || isSelected ? 0.30 : 0.18)
                        )
                    )
            } else {
                shape
                    .fill(.regularMaterial)
                    .overlay(shape.fill(backgroundFill.opacity(0.26)))
            }
            #else
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(backgroundFill.opacity(0.26)))
            #endif
        case .liquid:
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered || isSelected ? 0.42 : 0.30),
                                Color.white.opacity(0.08),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                )
        case .halo:
            shape
                .fill(.thinMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
                .overlay(
                    shape.fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(isHovered || isSelected ? 0.30 : 0.18),
                                Color.clear,
                            ],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: 54
                        )
                    )
                    .blendMode(.screen)
                )
        case .command:
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(Color.black.opacity(0.28)))
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .commandLight:
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(Color.white.opacity(0.22)))
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .outline:
            shape.fill(isHovered || isSelected ? backgroundFill.opacity(0.14) : Color.clear)
        case .flat:
            shape.fill(isHovered || isSelected ? backgroundFill.opacity(0.12) : Color.clear)
        }
#else
        shape.fill(backgroundFill)
#endif
    }

    @ViewBuilder
    private var buttonBorder: some View {
#if DEBUG
        let generation = debugStyleGeneration
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch generation >= 0 ? FeedButtonDebugSettings.visualStyle : .solid {
        case .solid:
            EmptyView()
        case .standardGlass:
            shape.stroke(Color.white.opacity(0.12), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .standardTintedGlass:
            shape.stroke(backgroundFill.opacity(0.22), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .glass:
            shape.stroke(Color.white.opacity(0.16), lineWidth: 0.75)
        case .nativeGlass:
            shape.stroke(Color.white.opacity(0.14), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .nativeProminentGlass:
            shape.stroke(Color.white.opacity(0.18), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .liquid:
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42),
                        backgroundFill.opacity(0.28),
                        Color.white.opacity(0.10),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: FeedButtonDebugSettings.borderWidth
            )
        case .halo:
            shape.stroke(
                backgroundFill.opacity(isHovered || isSelected ? 0.55 : 0.34),
                lineWidth: FeedButtonDebugSettings.borderWidth
            )
        case .command:
            shape.stroke(Color.white.opacity(0.12), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .commandLight:
            shape.stroke(Color.black.opacity(0.12), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .outline:
            shape.stroke(backgroundFill.opacity(0.75), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .flat:
            EmptyView()
        }
#else
        EmptyView()
#endif
    }

    private var buttonShadowColor: Color {
#if DEBUG
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .halo:
            return backgroundFill.opacity(isHovered || isSelected ? 0.44 : 0.24)
        case .liquid:
            return backgroundFill.opacity(isHovered || isSelected ? 0.18 : 0.10)
        case .command:
            return Color.black.opacity(0.28)
        case .commandLight:
            return Color.black.opacity(isHovered || isSelected ? 0.16 : 0.08)
        case .nativeProminentGlass:
            return backgroundFill.opacity(isHovered || isSelected ? 0.18 : 0.10)
        case .standardGlass, .standardTintedGlass, .solid, .glass, .nativeGlass, .outline, .flat:
            return Color.clear
        }
#else
        return Color.clear
#endif
    }

    private var buttonShadowRadius: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .halo: return isHovered || isSelected ? 9 : 6
        case .liquid: return isHovered || isSelected ? 5 : 3
        case .nativeProminentGlass: return isHovered || isSelected ? 5 : 3
        case .command: return 3
        case .commandLight: return isHovered || isSelected ? 4 : 2
        case .standardGlass, .standardTintedGlass, .solid, .glass, .nativeGlass, .outline, .flat: return 0
        }
#else
        return 0
#endif
    }

    private var buttonShadowY: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .halo: return 2
        case .liquid, .nativeProminentGlass, .command, .commandLight: return 1
        case .standardGlass, .standardTintedGlass, .solid, .glass, .nativeGlass, .outline, .flat: return 0
        }
#else
        return 0
#endif
    }
}

