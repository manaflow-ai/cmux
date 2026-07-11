public import CmuxAndroidEmulator
public import SwiftUI

/// Native picker for AVDs supplied by the user's Android SDK.
public struct AndroidEmulatorPickerView: View {
    @Bindable private var coordinator: AndroidEmulatorCoordinator
    private let onOpenInPane: (AndroidVirtualDevice) -> Void

    /// Creates a picker bound to one Android emulator coordinator.
    ///
    /// - Parameter coordinator: The coordinator that owns SDK discovery and lifecycle actions.
    public init(
        coordinator: AndroidEmulatorCoordinator,
        onOpenInPane: @escaping (AndroidVirtualDevice) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.onOpenInPane = onOpenInPane
    }

    /// Renders SDK discovery, AVD state, and lifecycle controls.
    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 320, minHeight: 240)
        .task {
            if case .idle = coordinator.loadState {
                await coordinator.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.portrait.and.arrow.forward")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "androidEmulator.title", defaultValue: "Android Emulators", bundle: .module))
                    .font(.system(size: 15, weight: .semibold))
                Text(String(
                    localized: "androidEmulator.subtitle",
                    defaultValue: "Uses Android tools already installed on this Mac.",
                    bundle: .module
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await coordinator.refresh() }
            } label: {
                Label(
                    String(localized: "androidEmulator.action.refresh", defaultValue: "Refresh", bundle: .module),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(coordinator.isRefreshing)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let snapshot):
            loadedContent(snapshot)
        case .failed(let error):
            unavailableContent(error)
        }
    }

    private func loadedContent(_ snapshot: AndroidEmulatorSnapshot) -> some View {
        VStack(spacing: 0) {
            if let actionError = coordinator.actionError {
                messageBanner(
                    icon: "exclamationmark.triangle.fill",
                    text: Self.errorDetail(actionError),
                    color: .orange,
                    dismissAction: coordinator.clearActionError
                )
            }

            if let warning = snapshot.warning {
                messageBanner(
                    icon: "exclamationmark.circle.fill",
                    text: warningText(warning),
                    color: .yellow,
                    action: warningAction(warning),
                    dismissAction: nil
                )
            }

            HStack(spacing: 6) {
                Text(String(localized: "androidEmulator.sdkPath", defaultValue: "SDK:", bundle: .module))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(snapshot.sdkRootURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.06))

            if snapshot.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "androidEmulator.empty.title", defaultValue: "No Android Virtual Devices", bundle: .module))
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(
                        localized: "androidEmulator.empty.detail",
                        defaultValue: "Create an Android Virtual Device in Android Studio, then refresh.",
                        bundle: .module
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(snapshot.devices) { device in
                    AndroidEmulatorDeviceRow(
                        device: device,
                        isLaunching: coordinator.launchingAVDNames.contains(device.name),
                        isStopping: device.state.serial.map(coordinator.stoppingSerials.contains) ?? false,
                        onLaunch: {
                            Task { await coordinator.launch(avdName: device.name) }
                        },
                        onStop: { serial, transportID in
                            Task {
                                await coordinator.stop(
                                    avdName: device.name,
                                    serial: serial,
                                    transportID: transportID
                                )
                            }
                        },
                        onOpenInPane: { onOpenInPane(device) }
                    )
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func unavailableContent(_ error: AndroidEmulatorError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(errorTitle(error))
                .font(.system(size: 15, weight: .semibold))
            Text(Self.errorDetail(error))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 430)
            Text(String(
                localized: "androidEmulator.install.detail",
                defaultValue: "Install Android Studio or the Android SDK command-line tools, create an AVD, then refresh.",
                bundle: .module
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 430)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageBanner(
        icon: String,
        text: String,
        color: Color,
        action: (title: String, isRunning: Bool, handler: () -> Void)? = nil,
        dismissAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let action {
                Button(action: action.handler) {
                    if action.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(action.title)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(action.isRunning)
            }
            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(
                    localized: "androidEmulator.action.dismiss",
                    defaultValue: "Dismiss",
                    bundle: .module
                ))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(color.opacity(0.09))
    }

    private func warningAction(
        _ warning: AndroidEmulatorWarning
    ) -> (title: String, isRunning: Bool, handler: () -> Void)? {
        guard case .adbQueryFailed = warning else { return nil }
        return (
            String(localized: "androidEmulator.action.restartADB", defaultValue: "Restart adb", bundle: .module),
            coordinator.isRestartingADB,
            { Task { await coordinator.restartADB() } }
        )
    }

    private func warningText(_ warning: AndroidEmulatorWarning) -> String {
        switch warning {
        case .adbMissing:
            return String(
                localized: "androidEmulator.warning.adbMissing",
                defaultValue: "Android Debug Bridge is not installed. Install adb so cmux can safely launch and stop AVDs.",
                bundle: .module
            )
        case .adbQueryFailed(let detail):
            let format = String(
                localized: "androidEmulator.warning.adbFailed",
                defaultValue: "Could not read running devices from adb: %@",
                bundle: .module
            )
            return String(format: format, detail)
        }
    }

    private func errorTitle(_ error: AndroidEmulatorError) -> String {
        switch error {
        case .sdkNotFound:
            return String(localized: "androidEmulator.error.sdkNotFound.title", defaultValue: "Android SDK Not Found", bundle: .module)
        case .emulatorMissing:
            return String(localized: "androidEmulator.error.emulatorMissing.title", defaultValue: "Android Emulator Not Installed", bundle: .module)
        default:
            return String(localized: "androidEmulator.error.command.title", defaultValue: "Android Emulator Unavailable", bundle: .module)
        }
    }

    static func errorDetail(_ error: AndroidEmulatorError) -> String {
        switch error {
        case .sdkNotFound:
            return String(
                localized: "androidEmulator.error.sdkNotFound.detail",
                defaultValue: "cmux checked ANDROID_HOME, ANDROID_SDK_ROOT, and ~/Library/Android/sdk.",
                bundle: .module
            )
        case .emulatorMissing(let sdkPath):
            let format = String(
                localized: "androidEmulator.error.emulatorMissing.detail",
                defaultValue: "The SDK at %@ does not contain the emulator component.",
                bundle: .module
            )
            return String(format: format, sdkPath)
        case .adbMissing(let sdkPath):
            let format = String(
                localized: "androidEmulator.error.adbMissing.detail",
                defaultValue: "The SDK at %@ does not contain Android Debug Bridge.",
                bundle: .module
            )
            return String(format: format, sdkPath)
        case .commandFailed(let tool, let detail):
            let format = String(
                localized: "androidEmulator.error.command.detail",
                defaultValue: "%@ failed: %@",
                bundle: .module
            )
            return String(format: format, tool, detail)
        case .avdNotFound(let name):
            let format = String(
                localized: "androidEmulator.error.avdNotFound.detail",
                defaultValue: "The AVD “%@” is no longer available. Refresh the list.",
                bundle: .module
            )
            return String(format: format, name)
        case .invalidEmulatorSerial(let serial):
            let format = String(
                localized: "androidEmulator.error.invalidSerial.detail",
                defaultValue: "Refused to stop the invalid emulator serial “%@”.",
                bundle: .module
            )
            return String(format: format, serial)
        case .launchFailed(let detail):
            let format = String(
                localized: "androidEmulator.error.launch.detail",
                defaultValue: "The vendor emulator could not launch: %@",
                bundle: .module
            )
            return String(format: format, detail)
        case .noConsolePortAvailable:
            return String(
                localized: "androidEmulator.error.noConsolePort.detail",
                defaultValue: "All supported Android emulator console ports are in use.",
                bundle: .module
            )
        case .launchNotConfirmed(let name):
            let format = String(
                localized: "androidEmulator.error.launchNotConfirmed.detail",
                defaultValue: "The AVD “%@” launched but did not appear in adb. Refresh to check again.",
                bundle: .module
            )
            return String(format: format, name)
        case .stopNotConfirmed(let serial):
            let format = String(
                localized: "androidEmulator.error.stopNotConfirmed.detail",
                defaultValue: "The emulator “%@” is still visible in adb. Refresh to check again.",
                bundle: .module
            )
            return String(format: format, serial)
        case .avdIdentityChanged(let expected, let actual):
            let format = String(
                localized: "androidEmulator.error.avdIdentityChanged.detail",
                defaultValue: "The emulator changed from AVD “%@” to “%@”. Refresh before stopping it.",
                bundle: .module
            )
            return String(format: format, expected, actual)
        }
    }
}
