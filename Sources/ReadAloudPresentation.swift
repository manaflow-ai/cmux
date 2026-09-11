import AppKit
import CmuxReadAloud
import SwiftUI

/// App-owned speech lifetime, settings window, and error presentation.
@MainActor
final class ReadAloudPresentation {
    private let preferences: ReadAloudPreferences
    private let coordinator: ReadAloudCoordinator
    private var settingsWindowController: NSWindowController?
    private var readTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    var isSpeaking: Bool { coordinator.isSpeaking }

    init() {
        let preferences = ReadAloudPreferences(
            defaults: .standard,
            keychainService: "\(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app").read-aloud"
        )
        self.preferences = preferences
        coordinator = ReadAloudCoordinator(
            synthesizer: MiniMaxSpeechClient(session: URLSession(configuration: .ephemeral)),
            preferences: preferences,
            player: PCMReadAloudPlayer()
        )
    }

    func read(_ text: String) {
        stop()
        let operation = generation
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.read(text)
            } catch is CancellationError {
                // Stop and replacement are deliberate, not user-facing failures.
            } catch {
                guard generation == operation else { return }
                if let error = error as? ReadAloudCoordinatorError,
                   case .configurationRequired = error {
                    showSettings()
                } else {
                    showError(error)
                }
            }
            if generation == operation { readTask = nil }
        }
    }

    func stop() {
        generation &+= 1
        readTask?.cancel()
        readTask = nil
        coordinator.stop()
    }

    func showSettings() {
        if let settingsWindowController {
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = ReadAloudSettingsModel(preferences: preferences)
        let content = NSHostingController(rootView: ReadAloudSettingsView(model: model))
        let window = NSWindow(contentViewController: content)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.readAloudSettings")
        window.title = String(localized: "readAloud.settingsTitle", defaultValue: "Read Aloud Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func showError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "readAloud.errorTitle", defaultValue: "Unable to Read Aloud")
        alert.informativeText = (error as? any LocalizedError)?.errorDescription
            ?? String(localized: "readAloud.errorMessage", defaultValue: "Speech playback failed. Check your connection and Read Aloud settings, then try again.")
        alert.addButton(withTitle: String(localized: "readAloud.dismiss", defaultValue: "OK"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
