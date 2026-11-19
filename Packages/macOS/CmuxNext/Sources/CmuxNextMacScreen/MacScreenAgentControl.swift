public import CmuxNextControl
import CmuxNextRemoteView
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The agent verbs on a Screen Sharing tab (every build; `cmux rd screenshot|click|type|key`,
/// cmux-tui cli/rd_agent.rs). They act only through a tab the person already has: nothing here
/// opens a tab, asks the hub for a session or a scope, or answers the host's approval.
/// - `mac_screen.frame` {tab, path}: writes the tab's newest decoded picture to `path` (absolute,
///   `.png`) as PNG; answers {path, width, height}.
/// - `mac_screen.input` {tab, frame?, events}: sends `events` on the tab's session as the pane sends
///   a person's input. Each is {"t":"pointer","x","y"} (stream pixels), {"t":"button","button"
///   (1 left, 2 middle, 3 right),"down"}, {"t":"key","usage" (HID),"down"} or {"t":"text","text"}.
///   `frame` ("WxH") is the size the caller mapped its pointer against; a different picture size
///   refuses, so a click never lands on a stale layout. Only a Full Control session takes input.
///   An empty `events` only checks that input would go through.
/// A refusal's code is `mac_screen.<state>` (``agentRefusal(_:forInput:)``), which the CLI turns
/// into the next command to run.
extension MacScreenPages {
    nonisolated static let agentMethods = ["mac_screen.frame", "mac_screen.input"]

    func registerAgent(on router: ControlRouter?) {
        router?.register([
            .async(Self.agentMethods[0]) { [weak self] call in
                guard let self else { return .null }
                return try await agentFrame(call.params)
            },
            .async(Self.agentMethods[1]) { [weak self] call in
                guard let self else { return .null }
                return try await agentInput(call.params)
            },
        ])
    }

    /// Where the tab stands when it can't answer a screenshot (or, `forInput`, take input):
    /// `mac_screen.<state>`, or nil when it can.
    static func agentRefusal(_ tab: MacScreenTab?, forInput: Bool) -> String? {
        guard let tab, !tab.record.isHome, let pane = tab.pane else { return "no_tab" }
        guard let hub = pane.model.hub, pane.model.gate == .open else { return "unsupported" }
        switch hub.phase {
        case .idle: return "connect_card"
        case .requesting, .approved: return "requesting"
        case .waitingForApproval: return "waiting_for_approval"
        case .streamFailed: return "stream_failed"
        case .declined: return "declined"
        case let .refused(refusal, _): return refusalName(refusal)
        case .revoked: return "revoked"
        case .ended: return "ended"
        case let .streaming(_, scope):
            // View Only takes no input: control is the host's person's grant, never asked from here.
            if forInput, scope != .full { return "view_only" }
        }
        guard let session = pane.session else { return "unsupported" }
        switch session.phase {
        case .connecting: return "connecting"
        case .failed: return "failed"
        case .ended: return "ended"
        case .connected: return pane.model.hasFrame ? nil : "no_frame"
        }
    }

    static func refusalName(_ refusal: MacScreenHubRefusal) -> String {
        switch refusal {
        case .permissionNone: "permission_none"
        case .scopeExceeds: "scope_exceeds"
        case .hostOffline: "host_offline"
        case .notShared: "not_shared"
        case .notFound: "not_found"
        case .notSignedIn: "not_signed_in"
        case .other: "refused"
        }
    }

    private static func refused(_ state: String) -> ControlError {
        ControlError(code: "mac_screen.\(state)", message: "Screen Sharing tab: \(state)", data: ["state": .string(state)])
    }

    private func agentTab(_ params: [String: JSONValue]) throws -> MacScreenTab? {
        guard let key = params["tab"]?.stringValue else { throw ControlError.invalidParams("tab: a Screen Sharing tab id") }
        return tabs[key]
    }

    func agentFrame(_ params: [String: JSONValue]) async throws -> JSONValue {
        let tab = try agentTab(params)
        guard let path = params["path"]?.stringValue, path.hasPrefix("/"), path.lowercased().hasSuffix(".png") else {
            throw ControlError.invalidParams("path: an absolute .png file path")
        }
        if let state = Self.agentRefusal(tab, forInput: false) { throw Self.refused(state) }
        guard let frame = tab?.pane?.session?.frameCounter?.latest else { throw Self.refused("no_frame") }
        // task-owner: one PNG write of a picture already decoded; the call waits for it
        let size = try await Task.detached(priority: .userInitiated) {
            try Self.writePNG(frame, to: URL(fileURLWithPath: path))
        }.value
        return ["path": .string(path), "width": .number(Double(size.width)), "height": .number(Double(size.height))]
    }

    /// Writes `frame` (the decoder's YUV or BGRA buffer) as an sRGB PNG; returns its pixel size.
    nonisolated static func writePNG(_ frame: RemoteDecodedFrame, to url: URL) throws -> (width: Int, height: Int) {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ControlError(code: "mac_screen.write_failed", message: "could not encode the picture") }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ControlError(code: "mac_screen.write_failed", message: "could not write \(url.path)")
        }
        return (cgImage.width, cgImage.height)
    }

    func agentInput(_ params: [String: JSONValue]) throws -> JSONValue {
        let tab = try agentTab(params)
        guard let list = params["events"]?.arrayValue else { throw ControlError.invalidParams("events: a list of input events") }
        var events: [RemoteInputEvent] = []
        for value in list {
            guard let parsed = Self.agentEvents(value) else { throw ControlError.invalidParams("events: pointer, button, key or text objects") }
            events += parsed
        }
        if let state = Self.agentRefusal(tab, forInput: true) { throw Self.refused(state) }
        guard let session = tab?.pane?.session else { throw Self.refused("no_tab") }
        let size = "\(Int(session.frameSize.width))x\(Int(session.frameSize.height))"
        if !events.isEmpty, let mapped = params["frame"]?.stringValue, mapped != size { throw Self.refused("frame_changed") }
        for event in events { session.send(event) }
        return ["sent": .number(Double(events.count)), "frame": .string(size)]
    }

    /// One `mac_screen.input` event as the pane's events (a long text splits on character boundaries).
    static func agentEvents(_ value: JSONValue) -> [RemoteInputEvent]? {
        switch value["t"]?.stringValue {
        case "pointer":
            guard let x = value["x"]?.intValue, let y = value["y"]?.intValue,
                  let x = Int32(exactly: x), let y = Int32(exactly: y), x >= 0, y >= 0 else { return nil }
            return [.pointer(x: x, y: y)]
        case "button":
            let number = value["button"]?.intValue ?? 1
            guard let raw = UInt8(exactly: number), let button = RemoteMouseButton(rawValue: raw) else { return nil }
            return [.button(button, down: value["down"]?.boolValue ?? true)]
        case "key":
            guard let usage = value["usage"]?.intValue, let usage = UInt32(exactly: usage) else { return nil }
            return [.key(usage: usage, down: value["down"]?.boolValue ?? true)]
        case "text":
            guard let text = value["text"]?.stringValue, !text.isEmpty else { return nil }
            return RemoteInputEvent.textEvents(text)
        default:
            return nil
        }
    }
}
