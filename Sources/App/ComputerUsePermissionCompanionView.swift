import AppKit
import SwiftUI

/// The borderless drag surface shown beside System Settings.
///
/// Both rows use the same fixed leading column and inter-column spacing, so the
/// instruction text and app tile share an exact leading edge. Text scales down
/// within that measured frame instead of being clipped when localization or
/// accessibility text sizes are longer.
@MainActor
struct ComputerUsePermissionCompanionView: View {
    let permissionStep: ComputerUseOnboardingStep
    @ObservedObject var presentationState: ComputerUseOnboardingPresentationState
    let applicationName: String
    let helperAppURL: URL?
    let onBack: @MainActor () -> Void
    let onDragEnded: @MainActor (NSDragOperation) -> Void
    let onLayoutReady: @MainActor () -> Void

    private let visualTokens = ComputerUseOnboardingVisualTokens.reference

    private var message: ComputerUsePermissionCompanionMessage {
        ComputerUsePermissionCompanionMessage.resolve(
            permissionStep: permissionStep,
            screenCaptureConsentPending: presentationState.screenCaptureConsentPending
        )
    }

    @Environment(\.colorScheme) private var colorScheme

    private var helperIcon: NSImage? {
        ComputerUseHelperIconRenderer.image(darkMode: colorScheme == .dark)
    }

    var body: some View {
        VStack(spacing: visualTokens.companionRowSpacing) {
            HStack(spacing: visualTokens.companionColumnSpacing) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(visualTokens.brandBlue)
                    .frame(
                        width: visualTokens.companionHeaderArrowSize,
                        height: visualTokens.companionHeaderArrowSize
                    )
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: Circle()
                    )
                    .frame(
                        width: visualTokens.companionLeadingColumnWidth,
                        height: visualTokens.companionHeaderHeight
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: visualTokens.gridUnit / 4) {
                    Text(instruction)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(visualTokens.compactTextMinimumScaleFactor)
                        .allowsTightening(true)

                    Text(followUp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(visualTokens.compactTextMinimumScaleFactor)
                        .allowsTightening(true)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: visualTokens.companionHeaderHeight,
                    maxHeight: visualTokens.companionHeaderHeight,
                    alignment: .leading
                )
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: visualTokens.companionColumnSpacing) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.72))
                .frame(
                    width: visualTokens.companionLeadingColumnWidth,
                    height: visualTokens.companionDragRowHeight
                )
                .background(
                    Color.primary.opacity(0.055),
                    in: RoundedRectangle(
                        cornerRadius: ComputerUsePermissionCompanionLayout.rowCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ComputerUsePermissionCompanionLayout.rowCornerRadius,
                        style: .continuous
                    )
                        .strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.32),
                            lineWidth: 0.5
                        )
                }
                .help(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
                .accessibilityLabel(
                    String(localized: "computerUse.onboarding.back", defaultValue: "Back")
                )

                helperDragTile
            }
        }
        .padding(.horizontal, visualTokens.companionHorizontalInset)
        .padding(.vertical, visualTokens.companionVerticalInset)
        .frame(
            width: visualTokens.companionSize.width,
            height: visualTokens.companionSize.height
        )
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(
                cornerRadius: visualTokens.companionCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: visualTokens.companionCornerRadius,
                style: .continuous
            )
                .strokeBorder(
                    Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 0.5
                )
        }
        .onAppear(perform: onLayoutReady)
    }

    /// A file-URL drag source accepted by the macOS permission lists.
    private var helperDragTile: some View {
        HStack(spacing: visualTokens.companionDragContentSpacing) {
            Group {
                if let helperIcon {
                    Image(nsImage: helperIcon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(
                width: visualTokens.companionHelperIconSize,
                height: visualTokens.companionHelperIconSize
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ComputerUsePermissionCompanionLayout.helperIconCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: ComputerUsePermissionCompanionLayout.helperIconCornerRadius,
                    style: .continuous
                )
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: 0.5
                    )
            }
            .accessibilityHidden(true)

            Text(applicationName)
                .font(
                    .system(
                        size: visualTokens.companionApplicationPointSize,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(visualTokens.compactTextMinimumScaleFactor)
                .allowsTightening(true)

            Spacer(minLength: visualTokens.gridUnit * 2)
        }
        .padding(.horizontal, visualTokens.companionDragHorizontalInset)
        .frame(
            maxWidth: .infinity,
            minHeight: visualTokens.companionDragRowHeight,
            maxHeight: visualTokens.companionDragRowHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(
                cornerRadius: ComputerUsePermissionCompanionLayout.rowCornerRadius,
                style: .continuous
            )
                .fill(Color.primary.opacity(0.055))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ComputerUsePermissionCompanionLayout.rowCornerRadius,
                        style: .continuous
                    )
                        .fill(Color.accentColor.opacity(0.035))
                }
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: ComputerUsePermissionCompanionLayout.rowCornerRadius,
                style: .continuous
            )
                .strokeBorder(
                    Color.accentColor.opacity(0.18),
                    lineWidth: 0.5
                )
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: ComputerUsePermissionCompanionLayout.rowCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            ComputerUseAppDragSource(
                helperAppURL: helperAppURL,
                helperIcon: helperIcon,
                onDragEnded: onDragEnded
            )
            .accessibilityHidden(true)
            .allowsHitTesting(helperAppURL != nil)
        }
        .help(String(
            localized: "computerUse.onboarding.dragTooltip",
            defaultValue: "Drag \(applicationName) into the permission list"
        ))
        .opacity(helperAppURL == nil ? 0.55 : 1)
    }

    private var instruction: String {
        switch message {
        case .dragIntoAccessibility:
            String(
                localized: "computerUse.onboarding.companion.accessibility",
                defaultValue: "Drag \(applicationName) into Accessibility"
            )
        case .dragIntoScreenshots:
            String(
                localized: "computerUse.onboarding.companion.screenRecording",
                defaultValue: "Drag \(applicationName) into Screenshots"
            )
        case .confirmScreenCapture:
            String(
                localized: "computerUse.onboarding.companion.confirmCapture",
                defaultValue: "Allow screen capture in the macOS alert"
            )
        }
    }

    private var followUp: String {
        switch message {
        case .dragIntoAccessibility, .dragIntoScreenshots:
            String(
                localized: "computerUse.onboarding.companion.turnOn",
                defaultValue: "Then turn it on."
            )
        case .confirmScreenCapture:
            String(
                localized: "computerUse.onboarding.companion.confirmCapture.detail",
                defaultValue: "The system “bypass” warning is expected here."
            )
        }
    }
}
