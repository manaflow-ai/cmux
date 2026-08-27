import AppKit
import SwiftUI

/// Shows one ``NewMachineSheet`` at a time as a window sheet on the main cmux
/// window (floating panel when no main window is on screen) and closes it
/// when the model finishes. AppKit owns the sheet window; this only keeps it
/// alive and ends the sheet on the host the presentation started on.
@MainActor
final class NewMachineSheetPresenter {
    static let shared = NewMachineSheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var model: NewMachineModel?

    private init() {}

    var isPresenting: Bool { sheetWindow != nil }

    /// Presents the sheet. A second request while one is up just re-raises the
    /// host window so the open sheet is where the person looks.
    func present(model: NewMachineModel, preferredWindow: NSWindow?) {
        if isPresenting {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: NewMachineSheet(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = model.isBaseSetup
            ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
            : String(localized: "machines.new.title", defaultValue: "New Machine")
        window.isReleasedWhenClosed = false
        model.onFinished = { [weak self] _ in
            self?.dismiss()
        }
        self.model = model
        sheetWindow = window

        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            host.beginSheet(window) { _ in }
        } else {
            // No host: float it. Cancel is the only way out, so no close button
            // can leave the presenter holding a window nobody sees.
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func dismiss() {
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetWindow = nil
        hostWindow = nil
        model = nil
    }
}
