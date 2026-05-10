import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct HostWindowEnumerator {
    func windows() async -> [HostWindow] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let windows = content.windows
                .compactMap(HostWindow.init(scWindow:))
                .filter(isUsableWindow)
                .sorted(by: sortWindows)

            if !windows.isEmpty {
                return windows
            }
        } catch {
            return coreGraphicsWindows()
        }

        return coreGraphicsWindows()
    }

    private func coreGraphicsWindows() -> [HostWindow] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindows
            .compactMap(HostWindow.init(windowInfo:))
            .filter(isUsableWindow)
            .sorted(by: sortWindows)
    }

    private func isUsableWindow(_ window: HostWindow) -> Bool {
        window.layer == 0 && (window.isOnScreen || window.hasTitle)
    }

    private func sortWindows(_ lhs: HostWindow, _ rhs: HostWindow) -> Bool {
        if lhs.isOnScreen != rhs.isOnScreen {
            return lhs.isOnScreen
        }
        if lhs.ownerName == rhs.ownerName {
            return lhs.area > rhs.area
        }
        return lhs.ownerName.localizedStandardCompare(rhs.ownerName) == .orderedAscending
    }
}
