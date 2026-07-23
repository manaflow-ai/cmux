import AppKit
import SwiftUI

/// Two-card onboarding for the standalone local computer-use helper.
///
/// Permissions belong to `cmux Computer Use`, which raises the native TCC
/// requests itself. A file-URL drag companion remains available as a recovery
/// path whenever a native request has not resulted in a completed grant.
@MainActor
struct ComputerUseOnboardingView: View {
    static let initialStep = ComputerUseOnboardingStep.overview

    let runtimeService: ComputerUseRuntimeService
    let initialStep: ComputerUseOnboardingStep
    let onSystemSettingsOpened: @MainActor () -> Void
    let onExpandedRequested: @MainActor () -> Void
    let onCompleted: @MainActor () -> Void

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
    @State private var nativePermissionRequestsAttempted: Set<ComputerUseOnboardingStep> = []

    init(
        runtimeService: ComputerUseRuntimeService,
        initialStep: ComputerUseOnboardingStep = .overview,
        onSystemSettingsOpened: @escaping @MainActor () -> Void = {},
        onExpandedRequested: @escaping @MainActor () -> Void = {},
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.runtimeService = runtimeService
        self.initialStep = initialStep
        self.onSystemSettingsOpened = onSystemSettingsOpened
        self.onExpandedRequested = onExpandedRequested
        self.onCompleted = onCompleted
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
        .ignoresSafeArea()
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

    private var onboardingBackground: some View {
        ZStack {
            Color(red: 0.157, green: 0.180, blue: 0.200)

            RadialGradient(
                colors: [.white.opacity(0.035), .clear],
                center: UnitPoint(x: 0.22, y: 0.02),
                startRadius: 0,
                endRadius: 220
            )
            RadialGradient(
                colors: [.black.opacity(0.22), .clear],
                center: UnitPoint(x: 0.08, y: 0.27),
                startRadius: 0,
                endRadius: 260
            )
            RadialGradient(
                colors: [.white.opacity(0.035), .clear],
                center: UnitPoint(x: 0.04, y: 0.96),
                startRadius: 0,
                endRadius: 290
            )
            RadialGradient(
                colors: [.black.opacity(0.10), .clear],
                center: UnitPoint(x: 0.70, y: 0.76),
                startRadius: 0,
                endRadius: 280
            )
        }
    }

    private var overviewSecondaryText: Color {
        Color(red: 0.66, green: 0.69, blue: 0.71)
    }

    private var permissionCardBackground: Color {
        Color(red: 0.161, green: 0.184, blue: 0.204)
    }

    /// The reference-style overview shown before entering a macOS permission pane.
    private var expandedOnboarding: some View {
        ZStack(alignment: .top) {
            onboardingBackground

            VStack(spacing: 0) {
                helperHeroIcon
                    .padding(.top, 55)
                    .offset(x: -1)

                Text(String(
                    localized: "computerUse.onboarding.hero.title",
                    defaultValue: "Enable cmux Computer Use"
                ))
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 19)
                .offset(y: -4)

                Text(String(
                    localized: "computerUse.onboarding.hero.detail",
                    defaultValue: "cmux Computer Use needs these permissions to use apps on your Mac.\nThese permissions are used when you ask cmux to perform tasks."
                ))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(overviewSecondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 15)
                .offset(y: -5)

                permissionOverview
                    .padding(.top, 12)
                    .offset(y: 1.5)

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
                    // The macOS app-icon canvas carries transparent safe-area
                    // padding. Scale the artwork, not its 52-point layout frame,
                    // so it reads at the same visual size as the reference icon.
                    .scaleEffect(1.24)
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
                    .foregroundStyle(overviewSecondaryText)
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
            permissionCardBackground,
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
            ZStack {
                Image(systemName: "camera.viewfinder")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 43, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Circle()
                    .fill(Color(red: 0.98, green: 0.76, blue: 0.16))
                    .frame(width: 5, height: 5)
                    .offset(x: 15, y: -9)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func permissionAction(
        for permissionStep: ComputerUseOnboardingStep,
        granted: Bool
    ) -> some View {
        let action = ComputerUsePermissionRowAction.resolve(
            granted: granted,
            nativeRequestAttempted: nativePermissionRequestsAttempted.contains(permissionStep)
        )
        if action == .done {
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
                    } else if action == .completeInSystemSettings {
                        Text(String(
                            localized: "computerUse.onboarding.completeInSystemSettings.short",
                            defaultValue: "Complete in System Settings"
                        ))
                        .font(.system(size: 11, weight: .semibold))
                    } else {
                        Text(String(localized: "computerUse.onboarding.allow", defaultValue: "Allow"))
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(
                    width: action == .completeInSystemSettings ? 157 : 57,
                    height: 24
                )
                .foregroundStyle(.white)
                .background(
                    action == .completeInSystemSettings
                        ? Color.white.opacity(0.12)
                        : Color.accentColor,
                    in: Capsule()
                )
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
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(permissionCompanionInstruction)
                        .font(.system(size: 19, weight: .bold))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 24)

                helperDragTile
                    .padding(.top, 20)

                Spacer(minLength: 44)
            }

            Button {
                isPermissionCompanionVisible = false
                onExpandedRequested()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.09), in: Circle())
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
            .accessibilityLabel(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
            .padding(.leading, 20)
            .padding(.bottom, 17)
        }
        .frame(width: 680, height: 250)
    }

    /// A file-URL drag source accepted by the macOS permission lists.
    private var helperDragTile: some View {
        HStack(spacing: 13) {
            Group {
                if let helperIcon {
                    Image(nsImage: helperIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 46, height: 46)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 30))
                        .frame(width: 46, height: 46)
                }
            }
            .accessibilityHidden(true)

            Text(runtimeService.applicationName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .frame(width: 282, height: 70, alignment: .leading)
        .background(permissionCardBackground, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
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
            defaultValue: "Drag \(runtimeService.applicationName) to the list above to allow Screenshots"
        )
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

        let action = ComputerUsePermissionRowAction.resolve(
            granted: permissionStep == .accessibility
                ? accessibilityGranted
                : screenRecordingGranted,
            nativeRequestAttempted: nativePermissionRequestsAttempted.contains(permissionStep)
        )
        if action == .completeInSystemSettings {
            presentPermissionCompanion(for: permissionStep)
            return
        }
        guard action == .allow else { return }

        step = permissionStep
        permissionSetupInFlight = true
        permissionCheckArmed = true
        Task { @MainActor in
            let didRequestPermission = if permissionStep == .accessibility {
                await runtimeService.requestAccessibility()
            } else {
                await runtimeService.requestScreenRecording()
            }
            nativePermissionRequestsAttempted.insert(permissionStep)
            permissionSetupInFlight = false

            guard !didRequestPermission else { return }

            // The pinned helper normally raises the native TCC request itself.
            // Its real app drag tile remains available as recovery when the
            // request cannot be issued, and after any accepted-but-unfinished
            // request through the row's "Complete in System Settings" action.
            presentPermissionCompanion(for: permissionStep)
        }
    }

    private func presentPermissionCompanion(for permissionStep: ComputerUseOnboardingStep) {
        step = permissionStep
        permissionCheckArmed = true
        isPermissionCompanionVisible = true
        openPermissionSettings(for: permissionStep)
    }

    private func openPermissionSettings(for permissionStep: ComputerUseOnboardingStep) {
        guard permissionStep == .accessibility || permissionStep == .screenRecording else { return }
        permissionCheckArmed = true
        onSystemSettingsOpened()
        Task { @MainActor in
            if permissionStep == .accessibility {
                _ = await runtimeService.openAccessibilitySettings()
            } else {
                _ = await runtimeService.openScreenRecordingSettings()
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

        if newAccessibilityGranted, newScreenRecordingGranted {
            isPermissionCompanionVisible = false
            onCompleted()
            return
        }

        let activePermissionWasGranted =
            (step == .accessibility && newAccessibilityGranted)
            || (step == .screenRecording && newScreenRecordingGranted)
        if isPermissionCompanionVisible, activePermissionWasGranted {
            isPermissionCompanionVisible = false
            onExpandedRequested()
        }
    }
}
