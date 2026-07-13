import AppKit
import Foundation

/// Diagnostics for compositing issues: with CEFKIT_LAYER_DUMP=1, every
/// browser dumps its host view's layer tree to stderr shortly after creation
/// (and again a few seconds later, once frames should be flowing). A healthy
/// embedded browser bottoms out in a CALayerHost whose contents come from the
/// GPU process; a missing CALayerHost means the remote-layer handshake never
/// completed.
enum CEFDebugDump {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CEFKIT_LAYER_DUMP"] == "1"
    }

    static func scheduleDump(for browser: CEFBrowser, label: String) {
        guard isEnabled else { return }
        for delay in [2.0, 6.0] {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak browser] _ in
                guard let browser, let host = browser.hostView else { return }
                dump(view: host, label: "\(label) t+\(delay)s")
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    static func dump(view: NSView, label: String) {
        var lines: [String] = ["CEFKIT_LAYER_DUMP[\(label)] window=\(view.window.map { String(describing: type(of: $0)) } ?? "nil")"]
        walkView(view, depth: 0, into: &lines)
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func walkView(_ view: NSView, depth: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        lines.append("\(pad)VIEW \(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) wantsLayer=\(view.wantsLayer)")
        if let layer = view.layer {
            walkLayer(layer, depth: depth + 1, into: &lines, viewBacked: true)
        }
        for subview in view.subviews {
            walkView(subview, depth: depth + 1, into: &lines)
        }
    }

    private static func walkLayer(_ layer: CALayer, depth: Int, into lines: inout [String], viewBacked: Bool = false) {
        let pad = String(repeating: "  ", count: depth)
        let contents = layer.contents.map { String(describing: type(of: $0)) } ?? "nil"
        lines.append(
            "\(pad)LAYER \(type(of: layer)) frame=\(layer.frame) hidden=\(layer.isHidden) opacity=\(layer.opacity) contents=\(contents)"
        )
        // View-backed sublayer trees are reported through their views; only
        // walk non-view layers here to keep the dump readable.
        for sub in layer.sublayers ?? [] where !viewBacked || sub.delegate == nil {
            walkLayer(sub, depth: depth + 1, into: &lines)
        }
    }
}
