import CmuxVNC
import CmuxVNCWebRTC
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// cmux-vnc-host: shares a VNC server (this Mac's Screen Sharing by default)
// with the cmux VNC iOS app over WebRTC.
//
//   cmux-vnc-host [--capture | --stream] [--user NAME] [--target HOST:PORT] [--name NAME] [--signal URL] [--new-pairing]
//
// --stream sends the screen as a WebRTC video track (hardware H.264) with
// input on a data channel, reading frames from --target's VNC server (this
// Mac's Screen Sharing) as --user; the password comes from CMUX_VNC_PASSWORD
// or ~/.config/cmux-vnc-host/password (mode 0600). Without --stream, RFB
// bytes ride a data channel to the viewer.
//
// The pairing (room and secret) is kept in ~/.config/cmux-vnc-host/pairing.json
// (mode 0600) so the phone stays paired across runs. Scan the printed QR code
// or open the link on the phone. The VNC server still asks for its own sign-in.

struct Options {
    var target = "127.0.0.1:5900"
    var name = Host.current().localizedName ?? "Mac"
    var signal = VNCPairing.defaultSignal
    var newPairing = false
    var stream = false
    /// ScreenCaptureKit + CGEvent instead of Screen Sharing (needs Screen
    /// Recording and Accessibility; run inside CmuxScreenHost.app).
    var capture = false
    var user: String?
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--target": options.target = arguments.isEmpty ? options.target : arguments.removeFirst()
    case "--name": options.name = arguments.isEmpty ? options.name : arguments.removeFirst()
    case "--signal": options.signal = arguments.isEmpty ? options.signal : (URL(string: arguments.removeFirst()) ?? options.signal)
    case "--new-pairing": options.newPairing = true
    case "--stream": options.stream = true
    case "--capture":
        options.stream = true
        options.capture = true
    case "--user": options.user = arguments.isEmpty ? nil : arguments.removeFirst()
    default:
        print("usage: cmux-vnc-host [--stream] [--user NAME] [--target HOST:PORT] [--name NAME] [--signal URL] [--new-pairing]")
        exit(flag == "--help" ? 0 : 2)
    }
}

let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cmux-vnc-host")
let file = folder.appendingPathComponent("pairing.json")
var pairing: VNCPairing
let kind = options.stream ? "stream" : "vnc"
if !options.newPairing, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(VNCPairing.self, from: data),
   saved.signal == options.signal, saved.kind == kind {
    pairing = saved
    pairing.name = options.name
} else {
    pairing = VNCPairing.generate(name: options.name, signal: options.signal, kind: kind)
}
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
if let data = try? JSONEncoder().encode(pairing) {
    FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
}

let parts = options.target.split(separator: ":")
let targetHost = parts.count > 1 ? parts.dropLast().joined(separator: ":") : options.target
let targetPort = parts.count > 1 ? parts.last.flatMap { UInt16($0) } ?? 5900 : 5900

/// The link as a terminal QR code (two rows per character).
func printQR(_ text: String) {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "L"
    guard let image = filter.outputImage else { return }
    let context = CIContext()
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
    func dark(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return pixels[((height - 1 - y) * width + x) * 4] < 128
    }
    for y in stride(from: -2, to: height + 2, by: 2) {
        var line = ""
        for x in -2 ..< width + 2 {
            switch (dark(x, y), dark(x, y + 1)) {
            case (true, true): line += " "
            case (true, false): line += "▄"
            case (false, true): line += "▀"
            case (false, false): line += "█"
            }
        }
        print(line)
    }
}

print("cmux VNC host: \(pairing.name) → \(targetHost):\(targetPort)")
print("Pair the cmux VNC app by scanning this code or opening the link on the iPhone:\n")
printQR(pairing.link.absoluteString)
print("\n\(pairing.link.absoluteString)\n")
setvbuf(stdout, nil, _IOLBF, 0)

let log: @Sendable (String) -> Void = { line in print("[\(Date().formatted(date: .omitted, time: .standard))] \(line)") }
if options.capture {
    let host = ScreenStreamHost(pairing: pairing, backend: { ScreenCaptureBackend(log: log) }, log: log)
    await host.run()
} else if options.stream {
    let password = ProcessInfo.processInfo.environment["CMUX_VNC_PASSWORD"]
        ?? (try? String(contentsOf: folder.appendingPathComponent("password"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = ScreenStreamHost(pairing: pairing, target: VNCEndpoint(host: targetHost, port: targetPort),
                                credentials: VNCCredentials(username: options.user, password: password), log: log)
    await host.run()
} else {
    await VNCWebRTCHost(pairing: pairing, targetHost: targetHost, targetPort: targetPort, log: log).run()
}
