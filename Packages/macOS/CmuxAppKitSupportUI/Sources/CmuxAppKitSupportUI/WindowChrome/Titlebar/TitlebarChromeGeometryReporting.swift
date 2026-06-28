public import AppKit
public import SwiftUI

/// Records titlebar-chrome geometry (control/hint frames and traffic-light frames) into the
/// XCUITest JSON capture file when the bonsplit tab-drag UI-test harness is active.
///
/// Replaces the former app-target `TitlebarChromeUITestRecorder` caseless namespace-enum with a
/// constructor-injected value type so the environment gating is testable and the package
/// convention against static-only namespaces is satisfied. Every method is `#if DEBUG`-gated;
/// in release builds they are no-ops.
public struct TitlebarChromeGeometryRecorder: Sendable {
    private let environment: [String: String]

    /// Creates a recorder reading its UI-test gating from `environment`.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// Records `frame` under `keyPrefix` into the capture payload, skipping degenerate frames.
    public func record(keyPrefix: String, frame: CGRect) {
#if DEBUG
        guard let path = dataPath(),
              frame.width > 1,
              frame.height > 1 else {
            return
        }
        var payload = loadPayload(at: path)
        payload["\(keyPrefix)X"] = String(format: "%.3f", Double(frame.minX))
        payload["\(keyPrefix)Y"] = String(format: "%.3f", Double(frame.minY))
        payload["\(keyPrefix)MinX"] = String(format: "%.3f", Double(frame.minX))
        payload["\(keyPrefix)MaxX"] = String(format: "%.3f", Double(frame.maxX))
        payload["\(keyPrefix)MinY"] = String(format: "%.3f", Double(frame.minY))
        payload["\(keyPrefix)MaxY"] = String(format: "%.3f", Double(frame.maxY))
        payload["\(keyPrefix)Width"] = String(format: "%.3f", Double(frame.width))
        payload["\(keyPrefix)Height"] = String(format: "%.3f", Double(frame.height))
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
#else
        _ = keyPrefix
        _ = frame
#endif
    }

    /// Records the close/minimize/zoom traffic-light button frames for `window`.
    @MainActor
    public func recordTrafficLightFrames(window: NSWindow?) {
#if DEBUG
        guard let window else { return }
        let buttons: [(String, NSWindow.ButtonType)] = [
            ("titlebarTrafficLightClose", .closeButton),
            ("titlebarTrafficLightMinimize", .miniaturizeButton),
            ("titlebarTrafficLightZoom", .zoomButton),
        ]
        for (keyPrefix, buttonType) in buttons {
            guard let button = window.standardWindowButton(buttonType),
                  !button.isHidden,
                  button.alphaValue > 0 else {
                continue
            }
            record(keyPrefix: keyPrefix, frame: button.convert(button.bounds, to: nil))
        }
#else
        _ = window
#endif
    }

#if DEBUG
    private func dataPath() -> String? {
        guard environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1",
              let path = environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func loadPayload(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif
}

/// SwiftUI wrapper that reports its backing AppKit view's window-space frame under `keyPrefix`
/// for XCUITest titlebar-chrome geometry assertions.
public struct TitlebarChromeGeometryReporter: NSViewRepresentable {
    private let keyPrefix: String

    /// Creates a reporter that records geometry under `keyPrefix`.
    public init(keyPrefix: String) {
        self.keyPrefix = keyPrefix
    }

    /// Creates the backing geometry-reporting view.
    public func makeNSView(context: Context) -> TitlebarChromeGeometryReportingView {
        let view = TitlebarChromeGeometryReportingView()
        view.keyPrefix = keyPrefix
        return view
    }

    /// Pushes the latest `keyPrefix` into the view and requests a report.
    public func updateNSView(_ nsView: TitlebarChromeGeometryReportingView, context: Context) {
        nsView.keyPrefix = keyPrefix
        nsView.reportSoon()
    }
}

/// AppKit view that records its own window-space frame whenever it moves window or relayouts.
public final class TitlebarChromeGeometryReportingView: NSView {
    /// Capture key prefix; reporting re-fires whenever it changes.
    public var keyPrefix = "" {
        didSet { reportSoon() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportSoon()
    }

    public override func layout() {
        super.layout()
        reportSoon()
    }

    /// Schedules a deferred geometry report (DEBUG-only; no-op in release).
    public func reportSoon() {
#if DEBUG
        DispatchQueue.main.async { [weak self] in
            self?.reportIfNeeded()
        }
#endif
    }

    private func reportIfNeeded() {
#if DEBUG
        guard window != nil,
              !keyPrefix.isEmpty,
              bounds.width > 1,
              bounds.height > 1 else {
            return
        }
        TitlebarChromeGeometryRecorder().record(keyPrefix: keyPrefix, frame: convert(bounds, to: nil))
#endif
    }
}
