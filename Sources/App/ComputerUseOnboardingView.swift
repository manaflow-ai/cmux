import AppKit
import SwiftUI

/// Non-blocking, one-permission-at-a-time onboarding for local computer use.
///
/// Permissions belong to the standalone `cmux Computer Use` helper. Each step
/// opens the matching System Settings pane, offers the helper as a real file-URL
/// drag source, and refreshes status from the helper's own TCC identity.
@MainActor
struct ComputerUseOnboardingView: View {
    static let initialStep = ComputerUseOnboardingStep.overview

    let runtimeService: ComputerUseRuntimeService
    let onSystemSettingsOpened: @MainActor () -> Void
    let onClose: () -> Void

    @State private var step = Self.initialStep
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var refreshInFlight = false
    @State private var permissionCheckArmed = false
    @State private var helperAppURL: URL?
    @State private var helperIcon: NSImage?

    init(
        runtimeService: ComputerUseRuntimeService,
        onSystemSettingsOpened: @escaping @MainActor () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.runtimeService = runtimeService
        self.onSystemSettingsOpened = onSystemSettingsOpened
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            progressPanel
            Divider()
            VStack(spacing: 0) {
                topBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 30)
                Divider()
                footer
            }
        }
        .frame(width: 760, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            prepareHelperForOnboarding()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard permissionCheckArmed else { return }
            permissionCheckArmed = false
            refreshPermissions()
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 48, height: 48)
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            Text(String(
                localized: "computerUse.onboarding.media.title",
                defaultValue: "Computer use"
            ))
            .font(.title3.weight(.semibold))
            .padding(.top, 16)

            Text(String(
                localized: "computerUse.onboarding.media.detail",
                defaultValue: "Let agents work across apps you choose"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 5)

            VStack(spacing: 8) {
                progressRow(
                    index: 0,
                    symbolName: "sparkles",
                    title: String(
                        localized: "computerUse.onboarding.overview.short",
                        defaultValue: "How it works"
                    )
                )
                progressRow(
                    index: 1,
                    symbolName: "accessibility",
                    title: String(
                        localized: "computerUse.onboarding.accessibility.short",
                        defaultValue: "Accessibility"
                    )
                )
                progressRow(
                    index: 2,
                    symbolName: "rectangle.inset.filled.and.person.filled",
                    title: String(
                        localized: "computerUse.onboarding.screenRecording.short",
                        defaultValue: "Screen Recording"
                    )
                )
            }
            .padding(.top, 28)

            Spacer()

            Label(
                String(
                    localized: "computerUse.onboarding.overview.local",
                    defaultValue: "Runs locally with separate cmux Computer Use permissions"
                ),
                systemImage: "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(26)
        .frame(width: 220)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.14),
                    Color(nsColor: .controlBackgroundColor).opacity(0.88),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func progressRow(index: Int, symbolName: String, title: String) -> some View {
        let progressIndex = min(step.rawValue, ComputerUseOnboardingStep.screenRecording.rawValue)
        let isCurrent = progressIndex == index
        let isComplete = step.rawValue > index
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: isComplete ? "checkmark" : symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isCurrent ? Color(nsColor: .windowBackgroundColor).opacity(0.74) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .animation(.easeInOut(duration: 0.18), value: step)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if step != .done {
                Text(String(
                    localized: "computerUse.onboarding.step",
                    defaultValue: "Step \(step.rawValue + 1) of 3"
                ))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            }

            ComputerUseWindowDragRegion()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            if step != .done {
                Button(
                    String(localized: "computerUse.onboarding.notNow", defaultValue: "Not Now"),
                    action: onClose
                )
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 26)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .overview:
            overview
        case .accessibility:
            permissionStep(
                title: String(
                    localized: "computerUse.onboarding.accessibility.title",
                    defaultValue: "Grant Accessibility"
                ),
                detail: String(
                    localized: "computerUse.onboarding.accessibility.detail",
                    defaultValue: "Accessibility lets the Computer Use helper inspect controls, click buttons, and type in apps you ask an agent to use."
                ),
                granted: accessibilityGranted,
                openSettings: {
                    openPermissionSettings(for: .accessibility)
                }
            )
        case .screenRecording:
            permissionStep(
                title: String(
                    localized: "computerUse.onboarding.screenRecording.title",
                    defaultValue: "Grant Screen Recording"
                ),
                detail: String(
                    localized: "computerUse.onboarding.screenRecording.detail",
                    defaultValue: "Screen Recording lets the Computer Use helper see app windows and screen content so it can act on what is visible."
                ),
                granted: screenRecordingGranted,
                openSettings: {
                    openPermissionSettings(for: .screenRecording)
                }
            )
        case .done:
            done
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(
                localized: "computerUse.onboarding.overview.title",
                defaultValue: "Agents can work across apps on this Mac"
            ))
            .font(.system(size: 26, weight: .semibold))

            Text(String(
                localized: "computerUse.onboarding.overview.detail",
                defaultValue: "When a task needs more than the terminal, supported agents can see and drive local apps. Permissions belong to a separate helper, so granting them never requires restarting cmux."
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 11) {
                overviewRow(
                    symbolName: "accessibility",
                    title: String(
                        localized: "computerUse.onboarding.accessibility.short",
                        defaultValue: "Accessibility"
                    ),
                    detail: String(
                        localized: "computerUse.onboarding.overview.accessibility",
                        defaultValue: "Control apps you choose"
                    )
                )
                overviewRow(
                    symbolName: "rectangle.inset.filled.and.person.filled",
                    title: String(
                        localized: "computerUse.onboarding.screenRecording.short",
                        defaultValue: "Screen Recording"
                    ),
                    detail: String(
                        localized: "computerUse.onboarding.overview.screenRecording",
                        defaultValue: "See app windows and screen content"
                    )
                )
            }
            .padding(.top, 2)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(String(
                    localized: "computerUse.onboarding.overview.restartHelper",
                    defaultValue: "Only the Computer Use helper needs to restart after permission changes. cmux stays open."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor.opacity(0.18)))
        }
    }

    private func overviewRow(symbolName: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.secondary.opacity(0.16)))
    }

    private func permissionStep(
        title: String,
        detail: String,
        granted: Bool,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                permissionReady
                    .padding(.top, 8)
            } else {
                HStack(spacing: 12) {
                    Button(
                        String(
                            localized: "computerUse.onboarding.openSystemSettings",
                            defaultValue: "Open System Settings"
                        ),
                        action: openSettings
                    )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer()
                    permissionStatus(granted: false)
                }

                helperDragTile

                HStack(spacing: 10) {
                    Label(
                        String(
                            localized: "computerUse.onboarding.dragTip",
                            defaultValue: "Drag the app card—not this window—into the permission list."
                        ),
                        systemImage: "hand.draw"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(
                        refreshInFlight
                            ? String(localized: "computerUse.onboarding.checking", defaultValue: "Checking…")
                            : String(localized: "computerUse.onboarding.checkAgain", defaultValue: "Check Again"),
                        action: refreshPermissions
                    )
                    .disabled(refreshInFlight)
                }
            }
        }
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

            VStack(alignment: .leading, spacing: 3) {
                Text(runtimeService.applicationName)
                    .font(.body.weight(.medium))
                Text(String(
                    localized: "computerUse.onboarding.dragHint",
                    defaultValue: "Drag this app into the list in System Settings, turn it on, then come back here."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
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
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.84), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.3)))
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

    private var permissionReady: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    localized: "computerUse.onboarding.permissionReady.title",
                    defaultValue: "Permission granted"
                ))
                .font(.body.weight(.medium))
                Text(String(
                    localized: "computerUse.onboarding.permissionReady.detail",
                    defaultValue: "You can continue to the next step."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.green.opacity(0.22)))
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(String(
                localized: "computerUse.onboarding.done.title",
                defaultValue: "Computer Use Is Ready"
            ))
            .font(.title2.weight(.semibold))
            Text(String(
                localized: "computerUse.onboarding.done.detailReady",
                defaultValue: "Both permissions belong to cmux Computer Use. cmux stays open while the helper refreshes. Return to your agent and retry the tool call."
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                permissionStatus(
                    granted: accessibilityGranted,
                    label: String(
                        localized: "computerUse.onboarding.accessibility.short",
                        defaultValue: "Accessibility"
                    )
                )
                permissionStatus(
                    granted: screenRecordingGranted,
                    label: String(
                        localized: "computerUse.onboarding.screenRecording.short",
                        defaultValue: "Screen Recording"
                    )
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .overview && step != .done {
                Button(String(localized: "computerUse.onboarding.back", defaultValue: "Back")) {
                    step = step.previous
                }
            }
            Spacer()
            if step != .done {
                Button(String(localized: "computerUse.onboarding.continue", defaultValue: "Continue")) {
                    continueOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    (step == .accessibility && !accessibilityGranted)
                        || (step == .screenRecording && !screenRecordingGranted)
                )
            } else {
                Button(
                    String(localized: "computerUse.onboarding.done", defaultValue: "Done"),
                    action: onClose
                )
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 64)
        .padding(.horizontal, 26)
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
        // A successful external drop is an explicit permission-setup action.
        // Refresh immediately so a drop into an already-open System Settings
        // pane cannot look like it failed, and keep the return-time refresh
        // armed in case the user still needs to turn the new row on.
        permissionCheckArmed = true
        refreshPermissions()
    }

    private func prepareHelperForOnboarding() {
        Task { @MainActor in
            _ = await runtimeService.ensureStandaloneHelperInstalled()
            refreshHelperPresentation()
        }
    }

    private func refreshHelperPresentation() {
        let url = runtimeService.helperAppURL
        helperAppURL = url
        helperIcon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private func applyPermissions(
        accessibilityGranted newAccessibilityGranted: Bool,
        screenRecordingGranted newScreenRecordingGranted: Bool
    ) {
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted

        if step == .accessibility, newAccessibilityGranted {
            if newScreenRecordingGranted {
                step = .done
            } else {
                continueOnboarding()
            }
        } else if step == .screenRecording, newScreenRecordingGranted {
            step = .done
        }
    }

    private func continueOnboarding() {
        let continuation = step.continuation
        step = continuation.nextStep
        if let settingsStep = continuation.settingsStepToOpen {
            openPermissionSettings(for: settingsStep)
        }
    }

    private func openPermissionSettings(for permissionStep: ComputerUseOnboardingStep) {
        guard permissionStep == .accessibility || permissionStep == .screenRecording else { return }
        permissionCheckArmed = true
        onSystemSettingsOpened()
        switch permissionStep {
        case .accessibility:
            runtimeService.requestAccessibility()
        case .screenRecording:
            runtimeService.requestScreenRecording()
        case .overview, .done:
            return
        }
    }
}
