// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// Artifact contents for the mock session: a few text files, a generated
/// screenshot and recording, directory listings and links.
public struct MockArtifactSource: ArtifactSource {
    /// Demo content has one deterministic owner, separate from every real Mac
    /// or account. Keep the sample grid's thumbnail warm cache.
    public let thumbnailCacheScope: String? = "mock-demo-artifacts-v1"

    public init() {}

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        switch artifact.kind {
        case .link:
            guard let url = URL(string: artifact.reference) else { throw ArtifactNotFound(reference: artifact.reference) }
            return .web(url)
        case .directory:
            return .directory(Self.children(of: artifact.reference))
        case .binary:
            return .binary(description: "Mach-O 64-bit executable arm64\n8.4 MB · built 2 min ago\n\(artifact.reference)")
        case .image:
            #if os(iOS)
            if let data = await Self.screenshotPNG() { return .image(data) }
            #endif
            throw ArtifactNotFound(reference: artifact.reference)
        case .video:
            #if os(iOS)
            if let url = try? await Self.recordingURL() { return .file(url) }
            #endif
            throw ArtifactNotFound(reference: artifact.reference)
        case .pdf:
            #if os(iOS)
            if let data = await Self.reportPDF() { return .pdf(data) }
            #endif
            throw ArtifactNotFound(reference: artifact.reference)
        default:
            if let text = Self.sampleText(for: artifact.reference) { return .text(text) }
            if artifact.kind == .code { return .text(Self.genericCode(for: artifact)) }
            throw ArtifactNotFound(reference: artifact.reference)
        }
    }

    /// A plausible file for code paths the samples don't cover (agent edits and reads).
    static func genericCode(for artifact: TerminalArtifact) -> String {
        switch artifact.fileExtension {
        case "swift":
            let type = artifact.name.replacingOccurrences(of: ".swift", with: "")
            return """
            import Foundation

            /// \(type): sample contents for \(artifact.reference).
            public struct \(type): Sendable {
                public var transport: TransportKind = .wireGuard

                public init() {}

                public func describe() -> String {
                    "\\(transport.displayName) link"
                }
            }
            """
        case "rs":
            return """
            //! \(artifact.reference)

            use crate::frame::Frame;

            pub fn encode(frame: &Frame) -> Vec<u8> {
                let mut out = Vec::with_capacity(9 + frame.payload.len());
                out.extend_from_slice(&(5 + frame.payload.len() as u32).to_be_bytes());
                out.extend_from_slice(&frame.channel.to_be_bytes());
                out.push(frame.kind as u8);
                out.extend_from_slice(&frame.payload);
                out
            }
            """
        default:
            return "// \(artifact.reference)\n"
        }
    }

    public static func children(of directory: String) -> [TerminalArtifact] {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        let names: [String] = switch base {
        case "src/", "./src/": ["link/", "main.rs", "lib.rs", "hostd.rs"]
        case "docs/": ["architecture.md", "protocol.md", "index.html"]
        case "screenshots/": ["terminal.png"]
        case "recordings/": ["demo.mp4"]
        case "cmux-next-ios/verify/", "verify/": ["transport-report.html", "transport.md", "screenshots/", "recordings/"]
        default: ["README.md", "Cargo.toml", "src/", "docs/"]
        }
        return names.enumerated().map { index, name in
            let reference = base + name
            let kind = name.hasSuffix("/") ? .directory : (TerminalArtifact.kind(forExtension: (name as NSString).pathExtension) ?? .text)
            return TerminalArtifact(reference: reference, kind: kind, order: index)
        }
    }

    public static func sampleText(for reference: String) -> String? {
        let name = reference.split(separator: "/").last.map(String.init) ?? reference
        switch name {
        case "README.md": return readme
        case "architecture.md", "protocol.md", "PROTOCOL.md": return architecture
        case "relay-rtt.csv": return "transport,region,p50_ms,p95_ms,samples\nwireguard,us-west,38,61,240\nwireguard,eu-central,52,88,240\nwebrtc,us-west,41,70,240\nwebrtc,eu-central,57,96,240\nrelay,us-west,63,112,240\nrelay,eu-central,79,141,240\n"
        case "index.html": return indexHTML
        case "mux.rs", "main.rs", "lib.rs", "hostd.rs": return muxRust
        case "Cargo.toml": return cargoToml
        case "TerminalScreen.swift": return swiftSample
        case "report.html", "transport-report.html": return reportHTML
        case "NOTES.md", "transport.md": return architecture
        case "Cargo.lock": return "# This file is automatically @generated by Cargo.\nversion = 4\n\n[[package]]\nname = \"cmux-mobile-host\"\nversion = \"0.1.0\"\n"
        default: return nil
        }
    }

    public static let reportHTML = """
    <!doctype html>
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root { color-scheme: light dark; }
      body { font: -apple-system-body; margin: 24px; }
      h1 { font-size: 26px; margin-bottom: 4px; }
      .sub { color: gray; margin-top: 0; }
      .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin: 20px 0; }
      .card { border-radius: 14px; padding: 14px; background: rgba(127,127,127,.12); }
      .num { font-size: 30px; font-weight: 700; }
      .ok { color: #2fbf71; }
      table { width: 100%; border-collapse: collapse; }
      td, th { text-align: left; padding: 8px 4px; border-bottom: 0.5px solid rgba(127,127,127,.4); }
    </style></head>
    <body>
      <h1>Transport switch</h1>
      <p class="sub">Test report · cmux-mobile-link</p>
      <div class="grid">
        <div class="card"><div class="num ok">45</div>tests passed</div>
        <div class="card"><div class="num">0</div>failures</div>
        <div class="card"><div class="num">38 ms</div>WireGuard RTT</div>
        <div class="card"><div class="num">52 ms</div>WebRTC RTT</div>
      </div>
      <table>
        <tr><th>Suite</th><th>Result</th></tr>
        <tr><td>LinkDialerTests</td><td class="ok">14 passed</td></tr>
        <tr><td>cmux-mobile-link</td><td class="ok">31 passed</td></tr>
      </table>
    </body></html>
    """

    static let readme = """
    # cmux-next

    The terminal multiplexer for agents, on your Mac and your phone.

    ## Quick start

    - `cargo build --release -p cmux-mobile-host`
    - `cmux-mobile-host pair` and scan the code in the cmux app
    - Open **Workspaces** and pick a terminal

    ## Layout

    | Path | What |
    | --- | --- |
    | `cmux-next-ios/` | the native iOS app |
    | `cmux-next-ios/rust/` | link, ffi and hostd crates |
    | `docs/` | architecture and protocol notes |

    > The phone never runs commands itself; it mirrors the Mac's terminals.

    ```sh
    cmux-mobile-host --listen 0.0.0.0:7420
    ```
    """

    static let architecture = """
    # Architecture

    The phone and the Mac share one **link**: a reliable ordered byte stream
    over WebRTC or WireGuard. Channels carry the daemon socket, acpmux and files.

    1. The phone opens odd channel ids, the Mac even.
    2. Frames are `u32 length | u32 channel | u8 type | payload`.
    3. `ping` and `pong` keep NAT bindings warm.

    See [the protocol](protocol.md) and `src/link/mux.rs`.
    """

    static let indexHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Build report</title>
      <style>
        body { font: -apple-system-body; background: #000; color: #eee; margin: 24px; }
        h1 { font-size: 28px; margin: 0 0 8px; }
        .ok { color: #30d158; }
        .card { background: #1c1c1e; border-radius: 16px; padding: 16px; margin: 12px 0; }
        code { font-family: ui-monospace, monospace; color: #64d2ff; }
      </style>
    </head>
    <body>
      <h1>cmux-mobile-host build</h1>
      <p class="ok">Finished release in 48.21 s</p>
      <div class="card"><b>Binary</b><br><code>target/release/cmux-mobile-host</code> 8.4 MB</div>
      <div class="card"><b>Warnings</b><br>9 unused variables in <code>src/link/mux.rs</code></div>
      <div class="card"><b>Tests</b><br>212 passed, 0 failed</div>
    </body>
    </html>
    """

    static let muxRust = """
    use bytes::{Buf, BufMut, BytesMut};
    use std::collections::HashMap;

    /// One frame of the link: `u32 length | u32 channel | u8 type | payload`.
    #[derive(Debug, Clone, PartialEq)]
    pub struct Frame {
        pub channel: u32,
        pub kind: FrameKind,
        pub payload: Vec<u8>,
    }

    #[derive(Debug, Clone, Copy, PartialEq)]
    pub enum FrameKind { Open = 0, Data = 1, Close = 2, Ping = 3, Pong = 4 }

    impl Frame {
        pub fn decode(buf: &mut BytesMut) -> Option<Frame> {
            if buf.len() < 9 { return None; }
            let length = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
            if buf.len() < 4 + length { return None; }
            buf.advance(4);
            let channel = buf.get_u32();
            let kind = match buf.get_u8() {
                0 => FrameKind::Open,
                1 => FrameKind::Data,
                2 => FrameKind::Close,
                3 => FrameKind::Ping,
                _ => FrameKind::Pong,
            };
            let payload = buf.split_to(length - 5).to_vec();
            Some(Frame { channel, kind, payload })
        }

        pub fn encode(&self, out: &mut BytesMut) {
            out.put_u32((self.payload.len() + 5) as u32);
            out.put_u32(self.channel);
            out.put_u8(self.kind as u8);
            out.extend_from_slice(&self.payload);
        }
    }

    // Channels the phone opened (odd ids) and their services.
    pub struct Mux { next_id: u32, open: HashMap<u32, String> }
    """

    static let cargoToml = """
    [package]
    name = "cmux-mobile-host"
    version = "0.1.0"
    edition = "2021"

    [dependencies]
    tokio = { version = "1.43", features = ["full"] }
    webrtc = "0.12"
    boringtun = "0.6"
    """

    static let swiftSample = """
    import SwiftUI

    /// The terminal screen: Ghostty, composer, key bar.
    public struct TerminalScreen: View {
        @State private var model: TerminalModel

        public var body: some View {
            TerminalControllerView(model: model)
                .ignoresSafeArea()
                .navigationTitle(model.title)
        }
    }
    """

    #if os(iOS)
    /// Rendered once: a real source's bytes arrive from the Mac, so the list rig measures the
    /// app's decode, not the mock's drawing.
    @MainActor private static var screenshot: Data?
    @MainActor private static var report: Data?

    @MainActor
    public static func screenshotPNG() async -> Data? {
        if let screenshot { return screenshot }
        screenshot = renderScreenshot()
        return screenshot
    }

    @MainActor
    private static func renderScreenshot() -> Data? {
        let size = CGSize(width: 390, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let colors = [UIColor.systemTeal, .systemPurple, .systemGreen, .systemOrange]
            for (index, color) in colors.enumerated() {
                color.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: CGRect(x: 20, y: 70 + CGFloat(index) * 52, width: 120 + CGFloat(index * 50), height: 36), cornerRadius: 10).fill()
            }
            let title = NSAttributedString(string: "cmux-next · terminal.png", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.white,
            ])
            title.draw(at: CGPoint(x: 20, y: 24))
        }
        return image.pngData()
    }

    /// A one-page generated PDF.
    @MainActor
    public static func reportPDF() async -> Data? {
        if let report { return report }
        report = renderReport()
        return report
    }

    @MainActor
    private static func renderReport() -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            context.beginPage()
            let title = NSAttributedString(string: "Transport switch: test report", attributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: UIColor.black,
            ])
            title.draw(at: CGPoint(x: 48, y: 56))
            let body = NSAttributedString(string: "WebRTC and WireGuard dial the same Link.\n\n• swift test: 14 passed\n• cargo test -p cmux-mobile-link: 31 passed\n• Relay fallback: verified on cellular", attributes: [
                .font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.darkGray,
            ])
            body.draw(in: CGRect(x: 48, y: 110, width: 516, height: 300))
        }
    }

    /// A 3 second generated recording, written once.
    public static func recordingURL() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-mobile-mock-demo.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = 360, height = 240
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                let barX = frame * (width - 60) / 90
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * bytesPerRow + x * 4
                        let inBar = x >= barX && x < barX + 60 && y > 90 && y < 150
                        pixels[offset] = inBar ? 230 : UInt8(20 + y / 8)
                        pixels[offset + 1] = inBar ? 200 : 20
                        pixels[offset + 2] = inBar ? 90 : UInt8(30 + x / 12)
                        pixels[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
    #endif
}
#endif
