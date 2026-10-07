import CmuxBrowserStream
import Foundation

/// A simulator seen through C2's `BrowserPageAttachment`, so the browser
/// channel session (encoder, packetizer, lane, recovery, bitrate) serves it
/// unchanged. The device screen is the "page" in points; pointer events with
/// a pressed button become touches; text and keys go to the device;
/// navigation and history do nothing (the policy refuses them first).
actor SimulatorPageAttachment: BrowserPageAttachment {
    private let device: any SimulatorAttachment
    private let name: String
    private let udid: String
    private var touching = false

    init(device: any SimulatorAttachment, name: String, udid: String) {
        self.device = device
        self.name = name
        self.udid = udid
    }

    var geometry: BrowserPageGeometry {
        get async {
            let screen = await device.screen
            return BrowserPageGeometry(cssWidth: screen.pointWidth, cssHeight: screen.pointHeight, backingScale: screen.scale)
        }
    }

    nonisolated var video: any BrowserVideoSource { device.video }

    func events() async -> AsyncStream<BrowserPageEvent> {
        let ended = await device.ended()
        let page = RbPage(url: "simulator://\(udid)", title: name)
        return AsyncStream { continuation in
            continuation.yield(.page(page))
            let task = Task {
                for await reason in ended {
                    continuation.yield(.closed(reason: reason))
                    break
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func apply(_ input: RbInputEvent) async {
        switch input {
        case .pointer(let kind, let x, let y, _, let buttons, _, _, _):
            switch kind {
            case .down:
                touching = true
                await device.touch(SimulatorTouch(phase: .began, x: x, y: y))
            case .move where touching && buttons != 0:
                await device.touch(SimulatorTouch(phase: .moved, x: x, y: y))
            case .up where touching, .leave where touching:
                touching = false
                await device.touch(SimulatorTouch(phase: .ended, x: x, y: y))
            default:
                break
            }
        case .imeCommit(let text, _):
            await device.text(text)
        case .key(let key):
            await device.key(key)
        case .wheel, .pinch, .imeSetComposition, .imeFinish, .imeCancel:
            break
        }
    }

    func load(_ url: URL) async throws {
        throw SimulatorCaptureError.unavailable("navigation")
    }

    func history(_ op: RbHistoryOp) async {}

    func pasteboard(_ items: [RbClipboardItem]) async {
        if let text = items.lazy.compactMap(\.plainText).first { await device.pasteboard(text) }
    }

    func setVisible(_ visible: Bool) async {}

    func detach() async {
        if touching {
            touching = false
            await device.touch(SimulatorTouch(phase: .ended, x: 0, y: 0))
        }
        await device.detach()
    }
}
