import CoreGraphics
import Foundation

struct HostWindowEnumerator {
    func windows() -> [HostWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindows
            .compactMap(HostWindow.init(windowInfo:))
            .filter { window in
                window.layer == 0
            }
            .sorted { lhs, rhs in
                if lhs.ownerName == rhs.ownerName {
                    return lhs.area > rhs.area
                }
                return lhs.ownerName.localizedStandardCompare(rhs.ownerName) == .orderedAscending
            }
    }
}
