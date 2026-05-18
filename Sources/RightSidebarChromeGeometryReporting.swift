import AppKit
import Foundation
import SwiftUI

struct RightSidebarChromeGeometry: Equatable {
    var frame: CGRect
    var isVisible: Bool
    var titlebarHeight: CGFloat
}

enum RightSidebarChromeGeometryRole {
    case modeBar
    case secondaryBar
    case named(String)
}

enum RightSidebarChromeUITestRecorder {
    static func shouldRecord() -> Bool {
#if DEBUG
        dataPath() != nil
#else
        false
#endif
    }

    static func record(role: RightSidebarChromeGeometryRole, geometry: RightSidebarChromeGeometry) {
#if DEBUG
        guard let path = dataPath(),
              geometry.isVisible,
              geometry.frame.width > 1,
              geometry.titlebarHeight > 0 else {
            return
        }

        var payload = loadPayload(at: path)
        switch role {
        case .modeBar:
            payload["rightSidebarModeBarMinY"] = String(format: "%.3f", Double(geometry.frame.minY))
            payload["rightSidebarModeBarMaxY"] = String(format: "%.3f", Double(geometry.frame.minY + geometry.titlebarHeight))
            payload["rightSidebarModeBarWidth"] = String(format: "%.3f", Double(geometry.frame.width))
            payload["rightSidebarModeBarHeight"] = String(format: "%.3f", Double(geometry.titlebarHeight))
            payload["rightSidebarTitlebarHeight"] = String(format: "%.3f", Double(geometry.titlebarHeight))
        case .secondaryBar:
            payload["rightSidebarSecondaryBarMinY"] = String(format: "%.3f", Double(geometry.frame.minY))
            payload["rightSidebarSecondaryBarMaxY"] = String(format: "%.3f", Double(geometry.frame.minY + geometry.titlebarHeight))
            payload["rightSidebarSecondaryBarWidth"] = String(format: "%.3f", Double(geometry.frame.width))
            payload["rightSidebarSecondaryBarHeight"] = String(format: "%.3f", Double(geometry.titlebarHeight))
        case .named(let keyPrefix):
            payload["\(keyPrefix)MinY"] = String(format: "%.3f", Double(geometry.frame.minY))
            payload["\(keyPrefix)MaxY"] = String(format: "%.3f", Double(geometry.frame.maxY))
            payload["\(keyPrefix)Width"] = String(format: "%.3f", Double(geometry.frame.width))
            payload["\(keyPrefix)Height"] = String(format: "%.3f", Double(geometry.titlebarHeight))
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
#else
        _ = geometry
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

struct RightSidebarChromeGeometryReporter: NSViewRepresentable {
    var role: RightSidebarChromeGeometryRole
    var isVisible: Bool
    var titlebarHeight: CGFloat

    func makeNSView(context: Context) -> RightSidebarChromeGeometryReportingView {
        let view = RightSidebarChromeGeometryReportingView()
        view.role = role
        view.isVisibleForReporting = isVisible
        view.titlebarHeight = titlebarHeight
        return view
    }

    func updateNSView(_ nsView: RightSidebarChromeGeometryReportingView, context: Context) {
        nsView.role = role
        nsView.isVisibleForReporting = isVisible
        nsView.titlebarHeight = titlebarHeight
        nsView.reportIfNeeded()
    }
}

final class RightSidebarChromeGeometryReportingView: NSView {
    var role: RightSidebarChromeGeometryRole = .modeBar {
        didSet { reportIfNeeded() }
    }

    var isVisibleForReporting = false {
        didSet { reportIfNeeded() }
    }

    var titlebarHeight: CGFloat = 0 {
        didSet { reportIfNeeded() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reportIfNeeded()
    }

    override func layout() {
        super.layout()
        reportIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportIfNeeded()
    }

    func reportIfNeeded() {
        guard RightSidebarChromeUITestRecorder.shouldRecord(),
              window != nil,
              bounds.width > 1,
              bounds.height > 1 else {
            return
        }

        RightSidebarChromeUITestRecorder.record(
            role: role,
            geometry: RightSidebarChromeGeometry(
                frame: convert(bounds, to: nil),
                isVisible: isVisibleForReporting,
                titlebarHeight: bounds.height
            )
        )
    }
}

extension View {
    func reportRightSidebarChromeGeometryForBonsplitUITest(
        role: RightSidebarChromeGeometryRole = .modeBar,
        isVisible: Bool,
        titlebarHeight: CGFloat
    ) -> some View {
        background(
            RightSidebarChromeGeometryReporter(
                role: role,
                isVisible: isVisible,
                titlebarHeight: titlebarHeight
            )
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    func reportRightSidebarChromeNamedGeometryForBonsplitUITest(
        keyPrefix: String?,
        isVisible: Bool
    ) -> some View {
        if let keyPrefix {
            background(
                RightSidebarChromeGeometryReporter(
                    role: .named(keyPrefix),
                    isVisible: isVisible,
                    titlebarHeight: 0
                )
                .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}
