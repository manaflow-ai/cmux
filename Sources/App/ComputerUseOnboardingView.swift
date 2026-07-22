import AppKit
import SwiftUI

/// Two-card onboarding for the standalone local computer-use helper.
///
/// Permissions belong to `cmux Computer Use`, which raises the native TCC
/// requests itself. A file-URL drag companion remains available only as a
/// recovery path when the helper cannot request a permission normally.
@MainActor
struct ComputerUseOnboardingView: View {
    static let initialStep = ComputerUseOnboardingStep.overview

    let runtimeService: ComputerUseRuntimeService
    let initialStep: ComputerUseOnboardingStep
    let onSystemSettingsOpened: @MainActor () -> Void
    let onExpandedRequested: @MainActor () -> Void

    @State private var step: ComputerUseOnboardingStep
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var refreshInFlight = false
    @State private var permissionCheckArmed = false
    @State private var helperAppURL: URL?
    @State private var helperIcon: NSImage?
    @State private var isPermissionCompanionVisible: Bool
    @State private var initialPermissionFlowStarted = false
    @State private var permissionSetupInFlight = false

    init(
        runtimeService: ComputerUseRuntimeService,
        initialStep: ComputerUseOnboardingStep = .overview,
        onSystemSettingsOpened: @escaping @MainActor () -> Void = {},
        onExpandedRequested: @escaping @MainActor () -> Void = {}
    ) {
        self.runtimeService = runtimeService
        self.initialStep = initialStep
        self.onSystemSettingsOpened = onSystemSettingsOpened
        self.onExpandedRequested = onExpandedRequested
        _step = State(initialValue: initialStep)
        _helperIcon = State(initialValue: runtimeService.presentationIcon)
        _isPermissionCompanionVisible = State(initialValue: false)
    }

    var body: some View {
        Group {
            if isPermissionCompanionVisible {
                permissionCompanion
            } else {
                expandedOnboarding
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(onboardingBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            prepareHelperForOnboarding()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard permissionCheckArmed else { return }
            permissionCheckArmed = false
            refreshPermissions()
        }
    }

    private var onboardingBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    /// The reference-style overview shown before entering a macOS permission pane.
    private var expandedOnboarding: some View {
        ZStack(alignment: .top) {
            onboardingBackground

            VStack(spacing: 0) {
                helperHeroIcon
                    .padding(.top, 55)

                Text(String(
                    localized: "computerUse.onboarding.hero.title",
                    defaultValue: "Enable cmux Computer Use"
                ))
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 19)

                Text(String(
                    localized: "computerUse.onboarding.hero.detail",
                    defaultValue: "cmux Computer Use needs these permissions to use apps on your Mac.\nThese permissions are used when you ask cmux to perform tasks."
                ))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 15)

                permissionOverview
                    .padding(.top, 12)

                Spacer(minLength: 35)
            }
            .padding(.horizontal, 38)

            ComputerUseWindowDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .accessibilityHidden(true)
        }
        .frame(width: 596, height: 435)
    }

    private var helperHeroIcon: some View {
        Group {
            if let helperIcon {
                Image(nsImage: helperIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 52, height: 52)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .accessibilityHidden(true)
    }

    private var permissionOverview: some View {
        VStack(spacing: 18) {
            permissionCard(
                permissionStep: .accessibility,
                granted: accessibilityGranted,
                title: String(
                    localized: "computerUse.onboarding.accessibility.short",
                    defaultValue: "Accessibility"
                ),
                detail: String(
                    localized: "computerUse.onboarding.accessibility.cardDetail",
                    defaultValue: "Allows cmux to access app interfaces"
                )
            )
            permissionCard(
                permissionStep: .screenRecording,
                granted: screenRecordingGranted,
                title: String(
                    localized: "computerUse.onboarding.screenshots.short",
                    defaultValue: "Screenshots"
                ),
                detail: String(
                    localized: "computerUse.onboarding.screenshots.cardDetail",
                    defaultValue: "cmux uses screenshots to know where to click"
                )
            )
        }
    }

    private func permissionCard(
        permissionStep: ComputerUseOnboardingStep,
        granted: Bool,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 16) {
            permissionIcon(for: permissionStep)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            permissionAction(for: permissionStep, granted: granted)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 25, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
    }

    @ViewBuilder
    private func permissionIcon(for permissionStep: ComputerUseOnboardingStep) -> some View {
        if permissionStep == .accessibility {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.14, green: 0.75, blue: 1), .blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                Image(systemName: "accessibility")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(2)
            .background(Color.blue, in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
        } else {
            Image(systemName: "camera.viewfinder")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 43, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func permissionAction(
        for permissionStep: ComputerUseOnboardingStep,
        granted: Bool
    ) -> some View {
        if granted {
            HStack(spacing: 7) {
                Text(String(localized: "computerUse.onboarding.done", defaultValue: "Done"))
                Image(systemName: "checkmark")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
        } else {
            Button {
                beginPermissionSetup(for: permissionStep)
            } label: {
                Group {
                    if permissionSetupInFlight, step == permissionStep {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Text(String(localized: "computerUse.onboarding.allow", defaultValue: "Allow"))
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(width: 57, height: 24)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(helperAppURL == nil || permissionSetupInFlight)
            .accessibilityHint(String(
                localized: "computerUse.onboarding.openSystemSettings",
                defaultValue: "Open System Settings"
            ))
        }
    }

    private var permissionCompanion: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 13) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(permissionCompanionInstruction)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }

            helperDragTile

            HStack(spacing: 10) {
                Button {
                    isPermissionCompanionVisible = false
                    onExpandedRequested()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
                .accessibilityLabel(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))

                Button(
                    String(
                        localized: "computerUse.onboarding.openSystemSettings",
                        defaultValue: "Open System Settings"
                    )
                ) {
                    beginPermissionSetup(for: step)
                }

                Spacer()
                permissionStatus(granted: currentPermissionGranted)
                Button(
                    refreshInFlight
                        ? String(localized: "computerUse.onboarding.checking", defaultValue: "Checking…")
                        : String(localized: "computerUse.onboarding.checkAgain", defaultValue: "Check Again"),
                    action: refreshPermissions
                )
                .disabled(refreshInFlight)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 680, height: 250)
    }

    /// A file-URL drag source accepted by the macOS permission lists.
    private var helperDragTile: some View {
        HStack(spacing: 14) {
            Group {
                if let helperIcon {
                    Image(nsImage: helperIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 32))
                        .frame(width: 48, height: 48)
                }
            }
            .accessibilityHidden(true)

            Text(runtimeService.applicationName)
                .font(.body.weight(.semibold))
            Spacer(minLength: 8)
            Label(
                String(localized: "computerUse.onboarding.dragAction", defaultValue: "Drag"),
                systemImage: "hand.draw.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 15)
        .frame(height: 78)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            ComputerUseAppDragSource(
                helperAppURL: helperAppURL,
                helperIcon: helperIcon,
                onDragEnded: handleHelperDragEnded
            )
            .accessibilityHidden(true)
            .allowsHitTesting(helperAppURL != nil)
        }
        .help(String(
            localized: "computerUse.onboarding.dragTooltip",
            defaultValue: "Drag \(runtimeService.applicationName) into the permission list"
        ))
        .opacity(helperAppURL == nil ? 0.55 : 1)
    }

    private var permissionCompanionInstruction: String {
        if step == .accessibility {
            return String(
                localized: "computerUse.onboarding.companion.accessibility",
                defaultValue: "Drag \(runtimeService.applicationName) to the list above to allow Accessibility"
            )
        }
        return String(
            localized: "computerUse.onboarding.companion.screenRecording",
            defaultValue: "Drag \(runtimeService.applicationName) to the list above to allow Screen Recording"
        )
    }

    private var currentPermissionGranted: Bool {
        step == .accessibility ? accessibilityGranted : screenRecordingGranted
    }

    private func permissionStatus(granted: Bool, label: String? = nil) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            if let label {
                Text(label)
            }
            Text(
                granted
                    ? String(localized: "computerUse.onboarding.status.granted", defaultValue: "Granted")
                    : String(localized: "computerUse.onboarding.status.notGranted", defaultValue: "Not Granted")
            )
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    private func refreshPermissions() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task { @MainActor in
            defer { refreshInFlight = false }
            let status = await runtimeService.refreshHelperStatus()
            refreshHelperPresentation()
            applyPermissions(
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording
            )
        }
    }

    private func handleHelperDragEnded(operation: NSDragOperation) {
        guard operation != [] else { return }
        permissionCheckArmed = true
        refreshPermissions()
    }

    private func prepareHelperForOnboarding() {
        Task { @MainActor in
            _ = await runtimeService.ensureStandaloneHelperInstalled()
            refreshHelperPresentation()
            let status = await runtimeService.refreshHelperStatus()
            accessibilityGranted = status.accessibility
            screenRecordingGranted = status.screenRecording

            guard initialStep != Self.initialStep, !initialPermissionFlowStarted else { return }
            initialPermissionFlowStarted = true

            if initialStep == .accessibility, !status.accessibility {
                beginPermissionSetup(for: .accessibility)
            } else if initialStep == .screenRecording, !status.screenRecording {
                beginPermissionSetup(for: initialStep)
            }
        }
    }

    private func beginPermissionSetup(for permissionStep: ComputerUseOnboardingStep) {
        guard
            permissionStep == .accessibility || permissionStep == .screenRecording,
            !permissionSetupInFlight
        else {
            return
        }
        step = permissionStep
        permissionSetupInFlight = true
        permissionCheckArmed = true
        Task { @MainActor in
            let didRequestPermission = if permissionStep == .accessibility {
                await runtimeService.requestAccessibility()
            } else {
                await runtimeService.requestScreenRecording()
            }

            guard !didRequestPermission else {
                permissionSetupInFlight = false
                return
            }

            // The pinned helper normally raises the native TCC request itself.
            // Keep the legacy drag companion as a recovery path for a stale or
            // unavailable helper, rather than replacing the reference UI during
            // the normal permission flow.
            isPermissionCompanionVisible = true
            onSystemSettingsOpened()
            let didOpenSettings = if permissionStep == .accessibility {
                await runtimeService.openAccessibilitySettings()
            } else {
                await runtimeService.openScreenRecordingSettings()
            }
            permissionSetupInFlight = false
            guard didOpenSettings else {
                permissionCheckArmed = false
                isPermissionCompanionVisible = false
                onExpandedRequested()
                return
            }
        }
    }

    private func refreshHelperPresentation() {
        let url = runtimeService.helperAppURL
        helperAppURL = url
        helperIcon = runtimeService.presentationIcon
    }

    private func applyPermissions(
        accessibilityGranted newAccessibilityGranted: Bool,
        screenRecordingGranted newScreenRecordingGranted: Bool
    ) {
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted

        let activePermissionWasGranted =
            (step == .accessibility && newAccessibilityGranted)
            || (step == .screenRecording && newScreenRecordingGranted)
        if isPermissionCompanionVisible, activePermissionWasGranted {
            isPermissionCompanionVisible = false
            onExpandedRequested()
        }
    }
}
