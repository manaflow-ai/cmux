#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its wire.
extension ChromiumHostPageView {
    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { edit(0) }
    @objc public func cut(_ sender: Any?) { edit(1) }
    @objc public func paste(_ sender: Any?) { edit(2) }
    @objc public override func selectAll(_ sender: Any?) { edit(3) }
    @objc public func undo(_ sender: Any?) { edit(4) }
    @objc public func redo(_ sender: Any?) { edit(5) }

    private func edit(_ command: Int32) {
        sendInput(ChromiumHostFrame(.edit, v: [command]))
    }
}
#endif
