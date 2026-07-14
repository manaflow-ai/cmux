import Foundation
import UniformTypeIdentifiers

/// MIME lookup for files served through the diff-viewer URL scheme.
struct MobileDiffMIMEType: Sendable {
    func value(forPath path: String) -> String {
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch pathExtension {
        case "mjs": "text/javascript"
        case "map": "application/json"
        case "wasm": "application/wasm"
        default: UTType(filenameExtension: pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        }
    }
}
