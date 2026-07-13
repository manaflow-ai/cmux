import Foundation

/// MIME lookup for files served through the diff-viewer URL scheme.
struct MobileDiffMIMEType: Sendable {
    func value(forPath path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "mjs", "js": "text/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "wasm": "application/wasm"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
