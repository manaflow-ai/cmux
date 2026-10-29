import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A read-only capture seam for the host. It is enabled only when capture
/// tooling provides CMUX_UI_LAYER_CONTROL_SOCKET; it never claims or forwards
/// commands to cmux's live control socket.
final class UiLayerControlServer: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "cmux.ui-layer-host.control")
    private var descriptor: Int32 = -1
    @MainActor private var recorder: Recorder?

    init?(socketPath: String?) {
        guard let socketPath, !socketPath.isEmpty else { return nil }
        self.socketPath = socketPath
    }

    func start() {
        queue.async { [weak self] in
            self?.serve()
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
        unlink(socketPath)
    }

    private func serve() {
        unlink(socketPath)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { return }
        descriptor = server

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, addressLength)
            }
        }
        guard bound == 0, listen(server, 8) == 0 else { return }

        while true {
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(0x0A) {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
            if request.count > 1 << 20 { return }
        }
        guard let line = request.firstRange(of: Data([0x0A])) else { return }
        let payload = request[..<line.lowerBound]
        let finished = DispatchSemaphore(value: 0)
        Task { @MainActor [weak self] in
            let response = self?.response(for: payload) ?? Self.error("host unavailable")
            response.withUnsafeBytes { bytes in
                _ = write(client, bytes.baseAddress, response.count)
            }
            finished.signal()
        }
        finished.wait()
    }

    @MainActor
    private func response(for payload: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let method = object["method"] as? String else {
            return Self.error("invalid request")
        }
        do {
            let result: [String: Any]
            switch method {
            case "system.identify":
                result = ["product": "cmux-ui-layer-host", "read_only": true]
            case "debug.appearance":
                result = ["ok": true]
            case "debug.window_snapshot":
                guard let params = object["params"] as? [String: Any],
                      let path = params["path"] as? String else { return Self.error("snapshot path missing") }
                try snapshot(to: URL(fileURLWithPath: path))
                result = ["path": path]
            case "debug.window_record":
                guard let params = object["params"] as? [String: Any],
                      let dir = params["dir"] as? String else { return Self.error("record directory missing") }
                let seconds = min(12, max(0.1, (params["seconds"] as? NSNumber)?.doubleValue ?? 3))
                guard recorder == nil else { return Self.error("a recording is running") }
                recorder = try Recorder(dir: URL(fileURLWithPath: dir), seconds: seconds) { [weak self] in
                    self?.recorder = nil
                }
                recorder?.start()
                result = ["dir": dir, "seconds": seconds]
            default:
                return Self.error("unsupported read-only method: \(method)")
            }
            return try JSONSerialization.data(withJSONObject: ["id": object["id"] ?? 1, "ok": true, "result": result]) + Data([0x0A])
        } catch {
            return Self.error(error.localizedDescription)
        }
    }

    @MainActor
    private func snapshot(to path: URL) throws {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let contentView = window.contentView else { throw SnapshotError.noWindow }
        contentView.displayIfNeeded()
        let rect = contentView.bounds
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: rect) else {
            throw SnapshotError.noBitmap
        }
        contentView.cacheDisplay(in: rect, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noBitmap
        }
        try data.write(to: path, options: .atomic)
    }

    @MainActor
    private final class Recorder {
        private let dir: URL
        private let seconds: Double
        private let onFinish: @MainActor () -> Void
        private let started = DispatchTime.now().uptimeNanoseconds
        private var timer: Timer?
        private var times: [Double] = []
        private var frame = 0
        private let ioQueue = DispatchQueue(label: "cmux.ui-layer-host.recording", qos: .userInitiated)
        private let writes = DispatchGroup()

        init(dir: URL, seconds: Double, onFinish: @escaping @MainActor () -> Void) throws {
            self.dir = dir
            self.seconds = seconds
            self.onFinish = onFinish
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func start() {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.tick()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func tick() {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            guard elapsed <= seconds else {
                timer?.invalidate()
                self.timer = nil
                finish()
                return
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let contentView = window.contentView else { return }
            contentView.displayIfNeeded()
            let rect = contentView.bounds
            guard let representation = contentView.bitmapImageRepForCachingDisplay(in: rect) else { return }
            contentView.cacheDisplay(in: rect, to: representation)
            guard let image = representation.cgImage else { return }
            let path = dir.appendingPathComponent(String(format: "frame-%05d.jpg", frame))
            times.append(elapsed)
            frame += 1
            writes.enter()
            ioQueue.async { [writes] in
                defer { writes.leave() }
                guard let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
        }

        private func finish() {
            let frames = ["times": times]
            ioQueue.async { [dir, writes, onFinish] in
                writes.wait()
                if let data = try? JSONSerialization.data(withJSONObject: frames) {
                    try? data.write(to: dir.appendingPathComponent("frames.json"), options: .atomic)
                }
                Task { @MainActor in onFinish() }
            }
        }
    }

    private enum SnapshotError: LocalizedError {
        case noWindow, noBitmap

        var errorDescription: String? {
            switch self {
            case .noWindow: return "host window is not visible"
            case .noBitmap: return "host window could not render a bitmap"
            }
        }
    }

    private static func error(_ message: String) -> Data {
        let object: [String: Any] = ["id": 1, "ok": false, "error": message]
        return (try? JSONSerialization.data(withJSONObject: object) + Data([0x0A])) ?? Data("{\"ok\":false}\n".utf8)
    }
}
