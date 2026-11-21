#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import UIKit

extension DemoDriver {
    /// `-cmux-mobile-demo large-preview`: a file beyond the former 24 MiB
    /// preview limit, through the real loader and gallery. The low-space variant
    /// injects zero available bytes without consuming the simulator disk.
    func largePreview(lowSpace: Bool = false) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard var presenter = windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let link = LargePreviewDemoLink()
        let capacity: (@Sendable (URL) throws -> Int64)? = lowSpace ? { @Sendable _ in 0 } : nil
        let source = LinkFileArtifactSource(macName: "Mac", baseDirectory: "/demo", availableCapacity: capacity) { link }
        FilePreviewRequest(reference: "/demo/sample.pdf", source: source).present(from: presenter)
    }
}

/// A single-page PDF with an unused 25 MiB stream. Its page content is small,
/// so the large-file fallback exercises Quick Look without enormous text layout.
/// The prefix, suffix and one bounded message are the only bytes held in memory.
private struct LargePreviewPDF: Sendable {
    let prefix: Data
    let suffix: Data
    let paddingBytes = 25 << 20

    init() {
        var header = "%PDF-1.4\n"
        var offsets: [Int] = []
        func object(_ body: String) {
            offsets.append(header.utf8.count)
            header += "\(offsets.count) 0 obj\n\(body)\nendobj\n"
        }
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 540] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>")
        object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let content = """
        0.97 0.97 0.97 rg 0 0 400 540 re f
        0.15 0.15 0.15 rg
        BT /F1 26 Tf 42 432 Td (Sample document) Tj ET
        BT /F1 16 Tf 42 392 Td (Large file preview) Tj ET
        0.75 0.75 0.75 RG 42 366 m 358 366 l S
        BT /F1 13 Tf 42 330 Td (This page arrived through the file link.) Tj ET
        BT /F1 13 Tf 42 306 Td (Open, share, or save the complete file.) Tj ET
        """
        object("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        offsets.append(header.utf8.count)
        header += "6 0 obj\n<< /Length \(paddingBytes) >>\nstream\n"
        let endStream = "\nendstream\nendobj\n"
        let xrefOffset = header.utf8.count + paddingBytes + endStream.utf8.count
        var trailer = endStream + "xref\n0 7\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010lld 00000 n \n", Int64(offset)) }
        trailer += "trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        prefix = Data(header.utf8)
        suffix = Data(trailer.utf8)
    }

    var count: Int { prefix.count + paddingBytes + suffix.count }

    func chunk(at offset: Int, count: Int) -> Data {
        let end = min(offset + count, self.count)
        var chunk = Data()
        chunk.reserveCapacity(end - offset)
        if offset < prefix.count { chunk.append(prefix[offset..<min(end, prefix.count)]) }
        let paddingStart = max(offset, prefix.count)
        let paddingEnd = min(end, prefix.count + paddingBytes)
        if paddingStart < paddingEnd { chunk.append(Data(repeating: 0, count: paddingEnd - paddingStart)) }
        let suffixStart = max(offset, prefix.count + paddingBytes)
        if suffixStart < end {
            chunk.append(suffix[(suffixStart - prefix.count - paddingBytes)..<(end - prefix.count - paddingBytes)])
        }
        return chunk
    }
}

private final class LargePreviewDemoLink: MacLink, Sendable {
    let transport: TransportKind = .wireGuard
    var states: AsyncStream<LinkState> { AsyncStream { $0.finish() } }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        guard (service == "file" || service == "file-preview"), args["path"] == "/demo/sample.pdf" else {
            throw LinkError(code: "not_found", message: "The demo file is unavailable.")
        }
        return LargePreviewDemoChannel(metadata: service == "file-preview")
    }

    func ping() async throws -> UInt32 { 0 }
    func close() async {}
}

private final class LargePreviewDemoChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let pdf = LargePreviewPDF()
    // receive and close may race when the preview is dismissed or times out.
    private let lock = NSLock()
    private var offset = 0
    private var closure: LinkError?
    private var sendsMetadata: Bool

    init(metadata: Bool) { sendsMetadata = metadata }

    var closedBy: LinkError? { lock.withLock { closure } }
    func send(_ data: Data) async throws {}

    func receive() async throws -> Data? {
        try Task.checkCancellation()
        return lock.withLock {
            guard closure == nil else { return nil }
            if sendsMetadata {
                sendsMetadata = false
                return Data("{\"size\":\(pdf.count)}".utf8)
            }
            guard offset < pdf.count else {
                closure = LinkError(code: "eof", message: "")
                return nil
            }
            let chunk = pdf.chunk(at: offset, count: 192 << 10)
            offset += chunk.count
            return chunk
        }
    }

    func close(code: String, reason: String) async {
        lock.withLock { closure = LinkError(code: code, message: reason) }
    }
}
#endif
