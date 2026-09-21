#if DEBUG
import AppKit
import CmuxUpdater
import CmuxFoundation
@preconcurrency import Sparkle
import SwiftUI

/// A DEBUG-only control surface for exercising update-pill and minimal-mode layout states.
@MainActor
final class UpdateStateDebugWindowController: ReleasingWindowController {
    static let shared = UpdateStateDebugWindowController()

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.updateState.title", defaultValue: "Update State Debug")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.updateStateDebug")
        window.minSize = NSSize(width: 400, height: 500)
        window.center()
        if let model = AppDelegate.shared?.updateViewModel {
            window.contentView = NSHostingView(rootView: UpdateStateDebugView(model: model))
        } else {
            window.contentView = NSHostingView(rootView: Text("Update controller is unavailable"))
        }
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow(activateApplication: true)
    }
}

private enum UpdateDebugState: String, CaseIterable, Identifiable {
    case idle
    case detected
    case preparingCheck
    case checking
    case available
    case startingDownload
    case downloading
    case extracting
    case installing
    case noUpdates
    case error

    var id: Self { self }

    var title: String {
        switch self {
        case .idle: return String(localized: "debug.updateState.idle", defaultValue: "Idle")
        case .detected: return String(localized: "debug.updateState.detected", defaultValue: "Background update detected")
        case .preparingCheck: return String(localized: "debug.updateState.preparingCheck", defaultValue: "Preparing check")
        case .checking: return String(localized: "debug.updateState.checking", defaultValue: "Checking")
        case .available: return String(localized: "debug.updateState.available", defaultValue: "Update available")
        case .startingDownload: return String(localized: "debug.updateState.startingDownload", defaultValue: "Starting download")
        case .downloading: return String(localized: "debug.updateState.downloading", defaultValue: "Downloading")
        case .extracting: return String(localized: "debug.updateState.extracting", defaultValue: "Extracting")
        case .installing: return String(localized: "debug.updateState.installing", defaultValue: "Installing")
        case .noUpdates: return String(localized: "debug.updateState.noUpdates", defaultValue: "No updates")
        case .error: return String(localized: "debug.updateState.error", defaultValue: "Error")
        }
    }
}

private struct UpdateStateDebugView: View {
    let model: UpdateStateModel
    @State private var selectedState: UpdateDebugState = .idle
    @State private var version = "9.9.9"
    @State private var errorScenario: DebugUpdateErrorScenario = .genericInstallFailure
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @State private var attemptTask: Task<Void, Never>?

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "debug.updateState.heading", defaultValue: "Exercise update UI states"))
                    .cmuxFont(.headline)
                Text(String(
                    localized: "debug.updateState.description",
                    defaultValue: "Use these presets to inspect the minimal-mode footer, update pill, and titlebar geometry without contacting an update feed."
                ))
                .cmuxFont(.subheadline)
                .foregroundStyle(.secondary)

                GroupBox(String(localized: "debug.updateState.presentation", defaultValue: "Presentation")) {
                    Toggle(
                        String(localized: "debug.updateState.minimalMode", defaultValue: "Minimal mode"),
                        isOn: Binding(
                            get: { isMinimalMode },
                            set: { workspacePresentationMode = $0 ? WorkspacePresentationModeSettings.Mode.minimal.rawValue : WorkspacePresentationModeSettings.Mode.standard.rawValue }
                        )
                    )
                    Text(String(
                        localized: "debug.updateState.minimalModeHint",
                        defaultValue: "Toggle this while a state is active to check the titlebar and footer transition."
                    ))
                    .cmuxFont(.footnote)
                    .foregroundStyle(.secondary)
                }

                GroupBox(String(localized: "debug.updateState.state", defaultValue: "State")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(String(localized: "debug.updateState.state", defaultValue: "State"), selection: $selectedState) {
                            ForEach(UpdateDebugState.allCases) { state in
                                Text(state.title).tag(state)
                            }
                        }
                        .labelsHidden()

                        if selectedState == .available || selectedState == .detected {
                            LabeledContent(String(localized: "debug.updateState.version", defaultValue: "Version")) {
                                TextField("9.9.9", text: $version)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                            }
                        }

                        if selectedState == .error {
                            Picker(String(localized: "debug.updateState.errorScenario", defaultValue: "Error scenario"), selection: $errorScenario) {
                                ForEach(DebugUpdateErrorScenario.allCases, id: \.self) { scenario in
                                    Text(scenario.menuTitle).tag(scenario)
                                }
                            }
                        }

                        HStack {
                            Button(String(localized: "debug.updateState.apply", defaultValue: "Apply state")) {
                                applySelectedState()
                            }
                            Button(String(localized: "debug.updateState.attempt", defaultValue: "Attempt Update")) {
                                runAttemptUpdateSequence()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox(String(localized: "debug.updateState.current", defaultValue: "Current model")) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(String(localized: "debug.updateState.effectiveState", defaultValue: "Effective state"), value: stateName(model.effectiveState))
                        LabeledContent(String(localized: "debug.updateState.pillText", defaultValue: "Pill text"), value: model.text.isEmpty ? "(hidden)" : model.text)
                        LabeledContent(String(localized: "debug.updateState.detectedVersion", defaultValue: "Detected version"), value: model.detectedUpdateVersion ?? "(none)")
                        LabeledContent(String(localized: "debug.updateState.minimalModeValue", defaultValue: "Minimal mode"), value: isMinimalMode ? "On" : "Off")
                    }
                    .cmuxFont(.footnote)
                }

                HStack {
                    Button(String(localized: "debug.updateState.reset", defaultValue: "Reset automatic state")) {
                        resetAutomaticState()
                    }
                    Spacer()
                    Button(String(localized: "debug.updateState.dismiss", defaultValue: "Dismiss update")) {
                        model.dismissDetectedAvailableUpdate()
                        model.setOverrideState(.idle)
                    }
                }
            }
            .padding(18)
        }
        .frame(minWidth: 400, minHeight: 500)
        .onDisappear {
            attemptTask?.cancel()
            attemptTask = nil
        }
    }

    private func applySelectedState() {
        attemptTask?.cancel()
        model.debugOverrideText = nil
        switch selectedState {
        case .idle:
            resetAutomaticState()
        case .detected:
            model.setOverrideState(nil)
            model.debugSetDetectedVersion(version)
        case .preparingCheck:
            model.setOverrideState(.preparingCheck(.init(cancel: {})))
        case .checking:
            model.setOverrideState(.checking(.init(cancel: {})))
        case .available:
            model.clearDetectedUpdate()
            model.setOverrideState(.updateAvailable(.init(appcastItem: makeAppcastItem(version: version), reply: { _ in })))
        case .startingDownload:
            model.clearDetectedUpdate()
            model.setOverrideState(.startingDownload)
        case .downloading:
            model.clearDetectedUpdate()
            model.setOverrideState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 50)))
        case .extracting:
            model.clearDetectedUpdate()
            model.setOverrideState(.extracting(.init(progress: 0.5)))
        case .installing:
            model.clearDetectedUpdate()
            model.setOverrideState(.installing(.init(isAutoUpdate: false, retryTerminatingApplication: {}, dismiss: {})))
        case .noUpdates:
            model.clearDetectedUpdate()
            model.setOverrideState(.notFound(.init(acknowledgement: {})))
        case .error:
            model.clearDetectedUpdate()
            model.debugShowUpdateError(errorScenario)
        }
    }

    private func runAttemptUpdateSequence() {
        attemptTask?.cancel()
        model.debugOverrideText = nil
        model.clearDetectedUpdate()
        model.setOverrideState(.checking(.init(cancel: {})))
        attemptTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            model.setOverrideState(.notFound(.init(acknowledgement: {})))
        }
    }

    private func resetAutomaticState() {
        attemptTask?.cancel()
        attemptTask = nil
        model.debugOverrideText = nil
        model.clearDetectedUpdate()
        model.setOverrideState(nil)
    }

    private func makeAppcastItem(version: String) -> SUAppcastItem {
        let enclosure: [String: Any] = [
            "url": "https://example.com/cmux.zip",
            "length": "1024",
            "sparkle:version": version,
            "sparkle:shortVersionString": version,
        ]
        return SUAppcastItem(dictionary: [
            "title": "cmux (version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": enclosure,
        ]) ?? SUAppcastItem.empty()
    }

    private func stateName(_ state: UpdateState) -> String {
        switch state {
        case .idle: return "idle"
        case .permissionRequest: return "permissionRequest"
        case .preparingCheck: return "preparingCheck"
        case .checking: return "checking"
        case .updateAvailable: return "updateAvailable"
        case .startingDownload: return "startingDownload"
        case .downloading: return "downloading"
        case .extracting: return "extracting"
        case .installing: return "installing"
        case .notFound: return "notFound"
        case .error: return "error"
        }
    }
}
#endif
