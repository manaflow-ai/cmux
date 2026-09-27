import AppKit
public import CmuxUpdater
import Observation
import SwiftUI

/// Runs "Switch to Nightly" / "Switch to Stable" for the menu, command palette and Settings.
///
/// Opens the other cmux app, or downloads, verifies and installs it with a cancellable
/// progress panel. When the other app is open it offers to quit this one; it never quits on
/// its own. Every entrypoint calls ``start(target:)`` on the one shared instance, so a second
/// request while a switch runs brings the progress panel forward instead of starting another.
@MainActor
public final class AppChannelSwitchPresenter {
    private let switcher: AppChannelSwitcher
    private let requestQuit: @MainActor () -> Void
    private let model = AppChannelSwitchProgressModel()
    private var task: Task<Void, Never>?
    private var panel: NSPanel?

    /// Creates a presenter.
    ///
    /// - Parameters:
    ///   - switcher: Performs the switch.
    ///   - requestQuit: Quits this app through its normal termination path, which keeps any
    ///     quit confirmation the user configured.
    public init(
        switcher: AppChannelSwitcher = AppChannelSwitcher(),
        requestQuit: @escaping @MainActor () -> Void
    ) {
        self.switcher = switcher
        self.requestQuit = requestQuit
    }

    /// The app name shown for `target`.
    public static func displayName(for target: AppChannelSwitchTarget) -> String {
        switch target {
        case .stable: "cmux"
        case .nightly: "cmux NIGHTLY"
        }
    }

    /// The menu, palette and Settings button title for switching to `target`.
    public static func actionTitle(for target: AppChannelSwitchTarget) -> String {
        switch target {
        case .stable: String(localized: "appChannelSwitch.action.stable", defaultValue: "Switch to Stable")
        case .nightly: String(localized: "appChannelSwitch.action.nightly", defaultValue: "Switch to Nightly")
        }
    }

    /// The app-menu title for switching to `target`, with the ellipsis of an item that opens UI.
    public static func menuTitle(for target: AppChannelSwitchTarget) -> String {
        switch target {
        case .stable: String(localized: "appChannelSwitch.menu.stable", defaultValue: "Switch to Stable…")
        case .nightly: String(localized: "appChannelSwitch.menu.nightly", defaultValue: "Switch to Nightly…")
        }
    }

    /// Starts switching to `target`, or brings the running switch forward.
    public func start(target: AppChannelSwitchTarget) {
        if task != nil {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        let name = Self.displayName(for: target)
        model.reset(appName: name)
        let switcher = switcher
        let model = model
        task = Task { [weak self] in
            let result: Result<AppChannelSwitchOutcome, any Error>
            do {
                let throttle = AppChannelSwitchPhaseThrottle()
                let outcome = try await switcher.switchTo(target) { phase in
                    guard throttle.shouldPublish(phase) else { return }
                    Task { @MainActor in
                        model.apply(phase)
                        self?.showPanelIfNeeded()
                    }
                }
                result = .success(outcome)
            } catch {
                result = .failure(error)
            }
            self?.finish(result, target: target)
        }
    }

    private func cancel() {
        task?.cancel()
    }

    private func finish(_ result: Result<AppChannelSwitchOutcome, any Error>, target: AppChannelSwitchTarget) {
        task = nil
        panel?.orderOut(nil)
        panel = nil
        switch result {
        case .success:
            offerToQuit(target: target)
        case .failure(let error):
            if error is CancellationError { return }
            showFailure(error, target: target)
        }
    }

    private func showPanelIfNeeded() {
        guard task != nil, panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = model.title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(
            rootView: AppChannelSwitchProgressView(model: model) { [weak self] in self?.cancel() }
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func offerToQuit(target: AppChannelSwitchTarget) {
        // The other app was just activated; bring this one back so the question is visible.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "appChannelSwitch.opened.title", defaultValue: "%@ is open"),
            Self.displayName(for: target)
        )
        alert.informativeText = String(
            localized: "appChannelSwitch.opened.detail",
            defaultValue: "Both apps can run side by side. Quit this one now?"
        )
        alert.addButton(withTitle: String(localized: "appChannelSwitch.opened.quit", defaultValue: "Quit This App"))
        alert.addButton(withTitle: String(localized: "appChannelSwitch.opened.keep", defaultValue: "Keep Open"))
        if alert.runModal() == .alertFirstButtonReturn {
            requestQuit()
        }
    }

    private func showFailure(_ error: any Error, target: AppChannelSwitchTarget) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "appChannelSwitch.failed.title", defaultValue: "Couldn't switch to %@"),
            Self.displayName(for: target)
        )
        alert.informativeText = Self.failureDetail(error)
        alert.addButton(withTitle: String(localized: "appChannelSwitch.failed.download", defaultValue: "Download Manually"))
        alert.addButton(withTitle: String(localized: "appChannelSwitch.failed.close", defaultValue: "Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(target.downloadURL())
        }
    }

    private static func failureDetail(_ error: any Error) -> String {
        guard let error = error as? AppChannelSwitchError else { return String(describing: error) }
        switch error {
        case .downloadFailed(let detail):
            return String(
                format: String(localized: "appChannelSwitch.failed.downloadDetail", defaultValue: "The download failed: %@"),
                detail
            )
        case .mountFailed(let detail):
            return String(
                format: String(localized: "appChannelSwitch.failed.mountDetail", defaultValue: "The disk image could not be opened: %@"),
                detail
            )
        case .appNotFoundInDiskImage:
            return String(
                localized: "appChannelSwitch.failed.appMissing",
                defaultValue: "The downloaded disk image does not contain the expected app."
            )
        case .verificationFailed:
            return String(
                localized: "appChannelSwitch.failed.verification",
                defaultValue: "The downloaded app did not pass code signature verification, so it was not installed."
            )
        case .destinationOccupied(let url):
            return String(
                format: String(localized: "appChannelSwitch.failed.occupied", defaultValue: "Another app is already installed at %@."),
                url.path
            )
        case .installFailed(let detail):
            return String(
                format: String(localized: "appChannelSwitch.failed.installDetail", defaultValue: "The app could not be installed: %@"),
                detail
            )
        case .launchFailed(let detail):
            return String(
                format: String(localized: "appChannelSwitch.failed.launchDetail", defaultValue: "The app could not be opened: %@"),
                detail
            )
        }
    }
}

@MainActor
@Observable
final class AppChannelSwitchProgressModel {
    var appName = ""
    var phase: AppChannelSwitchPhase = .downloading(fractionCompleted: nil)

    var title: String {
        String(
            format: String(localized: "appChannelSwitch.progress.title", defaultValue: "Switching to %@"),
            appName
        )
    }

    var status: String {
        switch phase {
        case .downloading:
            String(format: String(localized: "appChannelSwitch.progress.downloading", defaultValue: "Downloading %@…"), appName)
        case .verifying:
            String(localized: "appChannelSwitch.progress.verifying", defaultValue: "Verifying the code signature…")
        case .installing:
            String(localized: "appChannelSwitch.progress.installing", defaultValue: "Installing…")
        case .launching:
            String(format: String(localized: "appChannelSwitch.progress.launching", defaultValue: "Opening %@…"), appName)
        }
    }

    var fractionCompleted: Double? {
        if case .downloading(let fraction) = phase { return fraction }
        return nil
    }

    var canCancel: Bool {
        switch phase {
        case .downloading, .verifying: true
        case .installing, .launching: false
        }
    }

    /// Applies `phase` unless it would move backwards (a late download hop after verifying).
    func apply(_ phase: AppChannelSwitchPhase) {
        guard Self.rank(phase) >= Self.rank(self.phase) else { return }
        self.phase = phase
    }

    private static func rank(_ phase: AppChannelSwitchPhase) -> Int {
        switch phase {
        case .downloading: 0
        case .verifying: 1
        case .installing: 2
        case .launching: 3
        }
    }

    func reset(appName: String) {
        self.appName = appName
        phase = .downloading(fractionCompleted: nil)
    }
}

struct AppChannelSwitchProgressView: View {
    let model: AppChannelSwitchProgressModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.status)
                .font(.system(size: 13))
            if let fraction = model.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button(String(localized: "appChannelSwitch.progress.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancel)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Drops download progress updates that don't change the whole percent, so a large DMG
/// doesn't schedule one main-actor hop per network chunk.
final class AppChannelSwitchPhaseThrottle: @unchecked Sendable {
    // Justification for @unchecked Sendable: `lastPercent` is guarded by `lock`.
    private let lock = NSLock()
    private var lastPercent: Int?
    private var sawIndeterminate = false

    func shouldPublish(_ phase: AppChannelSwitchPhase) -> Bool {
        guard case .downloading(let fraction) = phase else { return true }
        return lock.withLock {
            guard let fraction else {
                defer { sawIndeterminate = true }
                return !sawIndeterminate
            }
            let percent = Int(fraction * 100)
            guard percent != lastPercent else { return false }
            lastPercent = percent
            return true
        }
    }
}
