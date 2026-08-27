import AppKit
import SwiftUI

enum TitlebarChromeUITestRecorder {
    static func record(keyPrefix: String, frame: CGRect) {
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

    static func recordTrafficLightFrames(window: NSWindow?) {
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
    private static func dataPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private static func loadPayload(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif
}

struct TitlebarChromeGeometryReporter: NSViewRepresentable {
    let keyPrefix: String

    func makeNSView(context: Context) -> TitlebarChromeGeometryReportingView {
        let view = TitlebarChromeGeometryReportingView()
        view.keyPrefix = keyPrefix
        return view
    }

    func updateNSView(_ nsView: TitlebarChromeGeometryReportingView, context: Context) {
        nsView.keyPrefix = keyPrefix
        nsView.reportSoon()
    }
}

final class TitlebarChromeGeometryReportingView: NSView {
    var keyPrefix = "" {
        didSet { reportSoon() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportSoon()
    }

    override func layout() {
        super.layout()
        reportSoon()
    }

    func reportSoon() {
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
        TitlebarChromeUITestRecorder.record(keyPrefix: keyPrefix, frame: convert(bounds, to: nil))
#endif
    }
}
