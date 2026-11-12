#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// The Density Lab's window (DEV builds): `cmux rpc debug.density_lab` opens it, or brings it to the
/// front. A utility panel that stays above the main window, so the chrome it tunes stays in view.
@MainActor
final class DensityLabWindow {
    private static var shared: DensityLabWindow?

    let model: DensityLabModel
    private let panel: NSPanel

    private init(services: AppServices) {
        model = DensityLabModel(targetWindow: { [weak services] in services?.windows.active?.window })
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                        styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.title = "Density Lab"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.densityLab")
        panel.setFrameAutosaveName("cmux.densityLab")
        panel.contentView = NSHostingView(rootView: DensityLabView(model: model))
        if !panel.setFrameUsingName("cmux.densityLab") { panel.center() }
    }

    /// Opens the lab (making it the first time) and answers its file and the density it edits.
    /// `capture: true` also captures every density.
    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let lab = shared ?? DensityLabWindow(services: services)
        shared = lab
        lab.panel.orderFrontRegardless()
        if let id = params["density"]?.stringValue { lab.model.select(id) }
        if params["capture"]?.boolValue == true { Task { await lab.model.captureAll() } }
        return .object(["file": .string(lab.model.fileURL.path), "density": .string(lab.model.selectedID),
                        "window_number": JSONValue(lab.panel.windowNumber)])
    }
}

extension AppControl {
    /// `debug.density_lab {density?, capture?}` (DEV builds): opens the Density Lab.
    func registerDensityLabDebugMethod(_ services: AppServices) {
        service?.router.register([
            .mainActor("debug.density_lab") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DensityLabWindow.show(call.params, services: services))
            },
        ])
    }
}
#endif
