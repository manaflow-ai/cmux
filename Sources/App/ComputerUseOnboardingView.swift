import AppKit
import SwiftUI

/// Non-blocking, one-permission-at-a-time onboarding for local computer use.
///
/// The bundled driver runs in embedded mode, so both permissions belong to cmux.
/// Each permission step opens the matching System Settings pane, refreshes when
/// the user returns, and provides an explicit fallback status check.
@MainActor
struct ComputerUseOnboardingView: View {
    let permissionService: ComputerUsePermissionService
    let onSystemSettingsOpened: @MainActor () -> Void
    let onClose: () -> Void

    @State private var step = 0
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var refreshInFlight = false

    init(
        permissionService: ComputerUsePermissionService,
        startsAtPermissionStep: Bool = false,
        onSystemSettingsOpened: @escaping @MainActor () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.permissionService = permissionService
        self.onSystemSettingsOpened = onSystemSettingsOpened
        self.onClose = onClose
        _step = State(initialValue: startsAtPermissionStep ? 1 : 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            mediaPanel
            Divider()
            VStack(spacing: 0) {
                topBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 26)
                Divider()
                footer
            }
        }
        .frame(width: 720, height: 500)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermissions()
        }
    }

    private var mediaPanel: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color(nsColor: .controlBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                Spacer(minLength: 58)
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 112, height: 112)
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                        .frame(width: 84, height: 84)
                        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                    Image(systemName: mediaSymbolName)
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.tint)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                .padding(.bottom, 22)

                Text(String(
                    localized: "computerUse.onboarding.media.title",
                    defaultValue: "Computer use"
                ))
                .font(.title3.weight(.semibold))

                Text(String(
                    localized: "computerUse.onboarding.media.detail",
                    defaultValue: "Let agents work across apps you choose"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.top, 7)

                Spacer()

                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index <= min(step, 2) ? Color.accentColor : Color.secondary.opacity(0.22))
                            .frame(width: index == min(step, 2) ? 24 : 8, height: 7)
                            .animation(.easeInOut(duration: 0.2), value: step)
                    }
                }
                .accessibilityHidden(true)
                .padding(.bottom, 26)
            }
        }
        .frame(width: 220)
    }

    private var mediaSymbolName: String {
        switch step {
        case 1: "accessibility"
        case 2: "rectangle.inset.filled.and.person.filled"
        case 3: "checkmark"
        default: "cursorarrow.rays"
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if step < 3 {
                Text(String(
                    localized: "computerUse.onboarding.step",
                    defaultValue: "Step \(step + 1) of 3"
                ))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }

            ComputerUseWindowDragRegion()
                .accessibilityHidden(true)

            if step < 3 {
                Button(
                    String(localized: "computerUse.onboarding.notNow", defaultValue: "Not Now"),
                    action: onClose
                )
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            overview
        case 1:
            permissionStep(
                title: String(
                    localized: "computerUse.onboarding.accessibility.title",
                    defaultValue: "Grant Accessibility"
                ),
                detail: String(
                    localized: "computerUse.onboarding.accessibility.detail",
                    defaultValue: "Accessibility lets cmux inspect controls, click buttons, and type in apps you ask an agent to use."
                ),
                granted: accessibilityGranted,
                openSettings: {
                    permissionService.requestAccessibility()
                    onSystemSettingsOpened()
                    refreshPermissions()
                }
            )
        case 2:
            permissionStep(
                title: String(
                    localized: "computerUse.onboarding.screenRecording.title",
                    defaultValue: "Grant Screen Recording"
                ),
                detail: String(
                    localized: "computerUse.onboarding.screenRecording.detail",
                    defaultValue: "Screen Recording lets cmux see app windows and screen content so it can act on what is visible."
                ),
                granted: screenRecordingGranted,
                openSettings: {
                    permissionService.requestScreenRecording()
                    onSystemSettingsOpened()
                    refreshPermissions()
                }
            )
        default:
            done
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: "computerUse.onboarding.overview.title",
                defaultValue: "Agents can work across apps on this Mac"
            ))
            .font(.title2.weight(.semibold))

            Text(String(
                localized: "computerUse.onboarding.overview.detail",
                defaultValue: "When a task needs more than the terminal, supported agents can see and drive local apps. You choose when Computer Use runs, and its permissions belong only to cmux."
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
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

            Label(
                String(
                    localized: "computerUse.onboarding.overview.local",
                    defaultValue: "Runs locally under cmux's macOS permissions"
                ),
                systemImage: "hand.raised"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                permissionReady
                    .padding(.top, 8)
            } else {
                Button(
                    String(
                        localized: "computerUse.onboarding.openSystemSettings",
                        defaultValue: "Open System Settings"
                    ),
                    action: openSettings
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(String(
                        localized: "computerUse.onboarding.permission.instructions",
                        defaultValue: "In System Settings, turn on \(permissionService.applicationName), then return here."
                    ))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.14)))

                HStack(spacing: 10) {
                    permissionStatus(granted: false)
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
                defaultValue: "Both permissions are granted. Supported agent sessions can now use local computer-use tools."
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
            if step > 0 && step < 3 {
                Button(String(localized: "computerUse.onboarding.back", defaultValue: "Back")) {
                    step -= 1
                }
            }
            Spacer()
            if step < 3 {
                Button(String(localized: "computerUse.onboarding.continue", defaultValue: "Continue")) {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    (step == 1 && !accessibilityGranted)
                        || (step == 2 && !screenRecordingGranted)
                )
            } else {
                Button(
                    String(localized: "computerUse.onboarding.done", defaultValue: "Done"),
                    action: onClose
                )
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 58)
        .padding(.horizontal, 24)
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
            await Task.yield()
            let status = permissionService.status()
            applyPermissions(
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording
            )
        }
    }

    private func applyPermissions(
        accessibilityGranted newAccessibilityGranted: Bool,
        screenRecordingGranted newScreenRecordingGranted: Bool
    ) {
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted

        if step == 1, newAccessibilityGranted {
            step = newScreenRecordingGranted ? 3 : 2
        } else if step == 2, newScreenRecordingGranted {
            step = 3
        }
    }
}
