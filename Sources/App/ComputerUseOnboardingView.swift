import AppKit
import SwiftUI

/// Two-card onboarding for the standalone local computer-use helper.
///
/// Permissions belong to `cmux Computer Use`. Each Allow action opens the
/// matching System Settings pane and presents the installed helper as a
/// Finder-compatible drag source.
@MainActor
struct ComputerUseOnboardingView: View {
    static let initialStep = ComputerUseOnboardingStep.overview

    let runtimeService: ComputerUseRuntimeService
    @ObservedObject var presentationState: ComputerUseOnboardingPresentationState
    let initialStep: ComputerUseOnboardingStep
    let onSystemSettingsOpened: @MainActor () -> Void
    let onExpandedRequested: @MainActor () -> Void
    let onCompleted: @MainActor () -> Void

    @State private var step: ComputerUseOnboardingStep
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var permissionStatusIsKnown = false
    @State private var refreshInFlight = false
    @State private var permissionCheckArmed = false
    @State private var helperAppURL: URL?
    @State private var helperIcon: NSImage?
    @State private var isPermissionCompanionVisible: Bool
    @State private var initialPermissionFlowStarted = false
    @State private var permissionSetupInFlight = false

    init(
        runtimeService: ComputerUseRuntimeService,
        presentationState: ComputerUseOnboardingPresentationState,
        initialStep: ComputerUseOnboardingStep = .overview,
        onSystemSettingsOpened: @escaping @MainActor () -> Void = {},
        onExpandedRequested: @escaping @MainActor () -> Void = {},
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.runtimeService = runtimeService
        self.presentationState = presentationState
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
        .onChange(of: presentationState.returnToOverviewGeneration) {
            guard isPermissionCompanionVisible else { return }
            isPermissionCompanionVisible = false
            step = .overview
            refreshPermissions()
        }
        .task(id: isPermissionCompanionVisible) {
            guard isPermissionCompanionVisible else { return }
            await refreshPermissionsNow()
            for await _ in runtimeService.permissionStatusEvents() {
                guard !Task.isCancelled, isPermissionCompanionVisible else { return }
                await refreshPermissionsNow()
            }
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
            .padding(.horizontal, 40)

            ComputerUseWindowDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .accessibilityHidden(true)
        }
        .frame(width: 600, height: 440)
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
            statusIsKnown: permissionStatusIsKnown,
            nativeRequestAttempted: false
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
                    } else {
                        Text(String(localized: "computerUse.onboarding.allow", defaultValue: "Allow"))
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(width: 57, height: 24)
                .foregroundStyle(.white)
                .background(
                    Color.accentColor,
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
        ZStack(alignment: .topLeading) {
            ZStack {
                Image(systemName: "arrow.up")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white)
                Image(systemName: "arrow.up")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 34)
            .offset(x: 65, y: 5)
            .accessibilityHidden(true)

            Text(permissionCompanionInstruction)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 418, height: 34, alignment: .leading)
                .offset(x: 103, y: 6)

            Button {
                isPermissionCompanionVisible = false
                onExpandedRequested()
                refreshPermissions()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 29, height: 29)
                    .background(Color.white.opacity(0.09), in: Circle())
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
            .accessibilityLabel(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
            .offset(x: 18, y: 55)

            helperDragTile
                .offset(x: 62, y: 48)
        }
        .frame(width: 532, height: 110)
    }

    /// A file-URL drag source accepted by the macOS permission lists.
    private var helperDragTile: some View {
        HStack(spacing: 8) {
            Group {
                if let helperIcon {
                    Image(nsImage: helperIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 19))
                        .frame(width: 26, height: 26)
                }
            }
            .accessibilityHidden(true)

            Text(runtimeService.applicationName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(width: 459, height: 42, alignment: .leading)
        .background(permissionCardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        Task { @MainActor in
            await refreshPermissionsNow()
        }
    }

    private func refreshPermissionsNow() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let status = await runtimeService.refreshHelperStatus()
        guard !Task.isCancelled else { return }
        refreshHelperPresentation()
        applyPermissions(
            statusIsKnown: runtimeService.permissionStatusIsKnown,
            accessibilityGranted: status.accessibility,
            screenRecordingGranted: status.screenRecording
        )
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
            permissionStatusIsKnown = runtimeService.permissionStatusIsKnown
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

        let granted = permissionStep == .accessibility
            ? accessibilityGranted
            : screenRecordingGranted
        guard !permissionStatusIsKnown || !granted else { return }

        step = permissionStep
        permissionSetupInFlight = true
        permissionCheckArmed = true
        Task { @MainActor in
            defer { permissionSetupInFlight = false }
            _ = await runtimeService.ensureStandaloneHelperInstalled()
            refreshHelperPresentation()
            guard helperAppURL != nil else { return }
            await presentPermissionCompanion(for: permissionStep)
        }
    }

    private func presentPermissionCompanion(
        for permissionStep: ComputerUseOnboardingStep
    ) async {
        step = permissionStep
        permissionCheckArmed = true
        if permissionStep == .accessibility {
            _ = await runtimeService.openAccessibilitySettings()
        } else {
            _ = await runtimeService.openScreenRecordingSettings()
        }
        guard !Task.isCancelled else { return }
        isPermissionCompanionVisible = true
        onSystemSettingsOpened()
    }

    private func refreshHelperPresentation() {
        let url = runtimeService.helperAppURL
        helperAppURL = url
        helperIcon = runtimeService.presentationIcon
    }

    private func applyPermissions(
        statusIsKnown: Bool,
        accessibilityGranted newAccessibilityGranted: Bool,
        screenRecordingGranted newScreenRecordingGranted: Bool
    ) {
        permissionStatusIsKnown = statusIsKnown
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted

        if statusIsKnown, newAccessibilityGranted, newScreenRecordingGranted {
            isPermissionCompanionVisible = false
            onCompleted()
            return
        }

        let activePermissionWasGranted =
            statusIsKnown
                && (
                    (step == .accessibility && newAccessibilityGranted)
                        || (step == .screenRecording && newScreenRecordingGranted)
                )
        if isPermissionCompanionVisible, activePermissionWasGranted {
            isPermissionCompanionVisible = false
            onExpandedRequested()
        }
    }
}
