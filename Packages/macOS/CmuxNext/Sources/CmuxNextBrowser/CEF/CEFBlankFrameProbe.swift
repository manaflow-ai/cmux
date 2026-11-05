#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// NEVER MERGE probe (STATUS 14261 slice 1): for 30 display frames after a detach or attach, reads the window
/// server's composite of the host view's window at the page's centre and counts the frames that do not show the
/// probe page's magenta (`debug.cef` tracker `probe_*`).
@MainActor
final class CEFBlankFrameProbe {
    private weak var view: NSView?
    private var phase = ""
    private var left = 0
    private var index = 0
    private var lastKey: Double?
    private lazy var client = FrameClient(owner: "probe.detach", isAnimation: false, on: .app) { [weak self] _ in
        self?.tick()
        return (self?.left ?? 0) > 0
    }

    func start(_ phase: String, view: NSView) {
        self.view = view
        self.phase = phase
        left = 30
        index = 0
        client.activate()
    }

    private func tick() {
        guard let view else { return stop() }
        let page = sample(phase, view: view)
        let key = "probe_\(phase)_first_nonpage"
        if !page, CEFHostView.trackerStats.probe[key] == nil { CEFHostView.trackerStats.probe[key] = Double(index) }
        index += 1
        left -= 1
        if left <= 0 { stop() }
    }

    private func stop() { left = 0 }

    /// One composite sample at the view's centre; true when it shows magenta.
    @discardableResult
    func sample(_ phase: String, view: NSView) -> Bool {
        CEFHostView.trackerStats.probe["probe_\(phase)_samples", default: 0] += 1
        let key = Double(NSApp.keyWindow?.windowNumber ?? 0)
        if let last = lastKey, last != key { CEFHostView.trackerStats.probe["probe_key_changes", default: 0] += 1 }
        lastKey = key
        CEFHostView.trackerStats.probe["probe_key_window"] = key
        // perf-gate-ok: never-merge probe branch (STATUS 14261 slice 1), DEBUG only
        guard let window = view.window, let image = window.compositedSnapshot() else {
            CEFHostView.trackerStats.probe["probe_\(phase)_no_image", default: 0] += 1
            return false
        }
        let scale = CGFloat(image.width) / max(window.frame.width, 1)
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let pixel = CGRect(x: (centre.x * scale).rounded(.down), y: ((window.frame.height - centre.y) * scale).rounded(.down),
                           width: 1, height: 1)
        guard let crop = image.cropping(to: pixel) else { return false }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drew = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew else { return false }
        let page = rgba[0] > 200 && rgba[1] < 70 && rgba[2] > 200
        if page { CEFHostView.trackerStats.probe["probe_\(phase)_page", default: 0] += 1 }
        CEFHostView.trackerStats.probe["probe_\(phase)_last_rgb"] = Double(Int(rgba[0]) << 16 | Int(rgba[1]) << 8 | Int(rgba[2]))
        return page
    }
}
#endif
