import Foundation
import SwiftUI

struct RightSidebarChromeGeometry: Equatable {
    var frame: CGRect
    var isVisible: Bool
    var titlebarHeight: CGFloat
}

struct RightSidebarChromeGeometryPreferenceKey: PreferenceKey {
    static var defaultValue = RightSidebarChromeGeometry(
        frame: .zero,
        isVisible: false,
        titlebarHeight: 0
    )

    static func reduce(value: inout RightSidebarChromeGeometry, nextValue: () -> RightSidebarChromeGeometry) {
        value = nextValue()
    }
}

enum RightSidebarChromeUITestRecorder {
    static func shouldRecord() -> Bool {
#if DEBUG
        dataPath() != nil
#else
        false
#endif
    }

    static func record(geometry: RightSidebarChromeGeometry) {
#if DEBUG
        guard let path = dataPath(),
              geometry.isVisible,
              geometry.frame.width > 1,
              geometry.titlebarHeight > 0 else {
            return
        }

        var payload = loadPayload(at: path)
        payload["rightSidebarModeBarMinY"] = String(format: "%.3f", Double(geometry.frame.minY))
        payload["rightSidebarModeBarMaxY"] = String(format: "%.3f", Double(geometry.frame.minY + geometry.titlebarHeight))
        payload["rightSidebarModeBarWidth"] = String(format: "%.3f", Double(geometry.frame.width))
        payload["rightSidebarModeBarHeight"] = String(format: "%.3f", Double(geometry.titlebarHeight))
        payload["rightSidebarTitlebarHeight"] = String(format: "%.3f", Double(geometry.titlebarHeight))

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

extension View {
    @ViewBuilder
    func reportRightSidebarChromeGeometryForBonsplitUITest(
        isVisible: Bool,
        titlebarHeight: CGFloat
    ) -> some View {
        if RightSidebarChromeUITestRecorder.shouldRecord() {
            background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RightSidebarChromeGeometryPreferenceKey.self,
                        value: RightSidebarChromeGeometry(
                            frame: proxy.frame(in: .global),
                            isVisible: isVisible,
                            titlebarHeight: titlebarHeight
                        )
                    )
                }
            }
            .onPreferenceChange(RightSidebarChromeGeometryPreferenceKey.self) { geometry in
                RightSidebarChromeUITestRecorder.record(geometry: geometry)
            }
        } else {
            self
        }
    }
}
