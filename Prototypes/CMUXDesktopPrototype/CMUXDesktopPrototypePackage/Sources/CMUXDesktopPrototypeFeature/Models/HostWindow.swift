import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct HostWindow: Identifiable, Equatable, Hashable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let frame: CGRect
    let layer: Int
    let alpha: Double
    let memoryUsage: Int?
    let isOnScreen: Bool

    var hasTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var area: CGFloat {
        frame.width * frame.height
    }

    func with(frame: CGRect, isOnScreen: Bool? = nil) -> HostWindow {
        HostWindow(
            id: id,
            ownerPID: ownerPID,
            ownerName: ownerName,
            title: title,
            frame: frame,
            layer: layer,
            alpha: alpha,
            memoryUsage: memoryUsage,
            isOnScreen: isOnScreen ?? self.isOnScreen
        )
    }

    static func == (lhs: HostWindow, rhs: HostWindow) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension HostWindow {
    init?(windowInfo: [String: Any]) {
        guard
            let windowIDNumber = windowInfo[kCGWindowNumber as String] as? NSNumber,
            let ownerPIDNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
            let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: boundsDictionary)
        else {
            return nil
        }

        let title = windowInfo[kCGWindowName as String] as? String ?? ""
        let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let memoryUsage = (windowInfo[kCGWindowMemoryUsage as String] as? NSNumber)?.intValue
        let isOnScreen = (windowInfo[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

        guard frame.width >= 40, frame.height >= 40, alpha > 0 else {
            return nil
        }

        self.id = CGWindowID(windowIDNumber.uint32Value)
        self.ownerPID = pid_t(ownerPIDNumber.int32Value)
        self.ownerName = ownerName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.memoryUsage = memoryUsage
        self.isOnScreen = isOnScreen
    }

    init?(scWindow: SCWindow) {
        guard scWindow.frame.width >= 40, scWindow.frame.height >= 40 else {
            return nil
        }

        let owner = scWindow.owningApplication
        self.id = scWindow.windowID
        self.ownerPID = owner?.processID ?? 0
        self.ownerName = owner?.applicationName ?? String(localized: "window.owner.unknown", defaultValue: "Unknown App", bundle: .module)
        self.title = scWindow.title ?? ""
        self.frame = scWindow.frame
        self.layer = scWindow.windowLayer
        self.alpha = 1
        self.memoryUsage = nil
        self.isOnScreen = scWindow.isOnScreen
    }
}
