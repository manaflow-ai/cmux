import Foundation

/// The shim's DragTarget calls (`cmux_shim_browser_drag_target_*`, task 050): drops into a detached
/// page. Each returns 0 when the browser is gone or the fork lacks API 31; in host mode the remote
/// shim sends each as one control op and returns 1.
nonisolated struct CEFShimDragTargetOps {
    /// browser, files, file count, text, url, url title, x, y, allowed operations, modifiers.
    let enter: @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?, Int32, UnsafePointer<CChar>?,
                               UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32, Int32, Int32) -> Int32
    /// browser, x, y, allowed operations, modifiers.
    let over: @convention(c) (Int32, Int32, Int32, Int32, Int32) -> Int32
    let leave: @convention(c) (Int32) -> Int32
    /// browser, x, y, modifiers.
    let drop: @convention(c) (Int32, Int32, Int32, Int32) -> Int32

    init(_ r: CEFShimLibrary.Resolver) throws(CEFShimLibrary.LoadError) {
        enter = try r("cmux_shim_browser_drag_target_enter")
        over = try r("cmux_shim_browser_drag_target_over")
        leave = try r("cmux_shim_browser_drag_target_leave")
        drop = try r("cmux_shim_browser_drag_target_drop")
    }

    /// Makes `event`'s call for `browser`. One-way: the page answers with DRAG_OPERATION.
    func send(_ event: ChromiumHostDragEvent, browser: Int32) {
        switch event {
        case .enter(let data, let point, let allowed, let modifiers):
            Self.withCStrings(data.files) { files in
                Self.withCString(data.text) { text in
                    Self.withCString(data.url) { url in
                        Self.withCString(data.urlTitle) { title in
                            _ = enter(browser, files, Int32(data.files.count), text, url, title, point.x, point.y, allowed, modifiers)
                        }
                    }
                }
            }
        case .over(let point, let allowed, let modifiers):
            _ = over(browser, point.x, point.y, allowed, modifiers)
        case .leave:
            _ = leave(browser)
        case .drop(let point, let modifiers):
            _ = drop(browser, point.x, point.y, modifiers)
        }
    }

    /// `strings` as a C array of C strings, valid during `body`.
    private static func withCStrings(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Void) {
        let copies = strings.map { strdup($0) }
        let array = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: max(copies.count, 1))
        defer {
            array.deallocate()
            copies.forEach { free($0) }
        }
        for (index, copy) in copies.enumerated() { array[index] = UnsafePointer(copy) }
        body(UnsafePointer(array))
    }

    /// `string` as a C string valid during `body`; nil stays NULL.
    private static func withCString(_ string: String?, _ body: (UnsafePointer<CChar>?) -> Void) {
        guard let string else { return body(nil) }
        string.withCString { body($0) }
    }
}

/// A pane's page view drags into the browser its pane shows (``ChromiumHostDragWire``), through the
/// runtime's shim: the remote shim in host mode, whose ops reach the Chromium Host's DragTarget calls.
final class CEFPaneDragWire: ChromiumHostDragWire {
    private weak var pane: CEFPaneHost?

    init(pane: CEFPaneHost) {
        self.pane = pane
    }

    /// The shown tab's browser, while the host's fork takes drops into a detached page.
    var dragBrowser: Int32? {
        guard let pane, pane.runtime.forkAPIVersion >= ChromiumHostDragDestination.forkAPI else { return nil }
        return pane.visibleTab?.browserID
    }

    func send(_ event: ChromiumHostDragEvent, browser: Int32) {
        pane?.runtime.shim?.dragTarget.send(event, browser: browser)
    }
}
