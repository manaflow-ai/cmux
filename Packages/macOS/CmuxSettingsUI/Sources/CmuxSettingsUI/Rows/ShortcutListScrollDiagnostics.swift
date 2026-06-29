#if DEBUG
import AppKit
import SwiftUI

// MARK: - NSViewRepresentable

/// An invisible diagnostic overlay that measures the page `NSScrollView`'s
/// document-height and clip-origin on every frame/bounds change.
///
/// Drop it in `.background` of the tall Settings `ScrollView`:
///
/// ```swift
/// ScrollView { ... }
///     .background { ShortcutListScrollDiagnostics() }
/// ```
///
/// The view does nothing unless the environment variable
/// `CMUX_SCROLL_DIAG=1` is set; when it is, every frame/bounds notification
/// from the enclosing scroll view is appended as a CSV line to the path in
/// `CMUX_SCROLL_DIAG_FILE` (default `/tmp/cmux-scroll-diag.csv`).
///
/// CSV format (one-line header then data):
/// ```
/// # t,event,docH,clipOriginY
/// 12345.678,frame,16605.0,0.0
/// 12345.689,bounds,16605.0,14900.5
/// ```
///
/// Columns:
/// - `t` — `ProcessInfo.systemUptime` (seconds, monotonic)
/// - `event` — `"frame"` (documentView frame changed) or
///   `"bounds"` (contentView/clip bounds changed)
/// - `docH` — `documentView.frame.height`
/// - `clipOriginY` — `contentView.bounds.origin.y`
struct ShortcutListScrollDiagnostics: NSViewRepresentable {
    func makeNSView(context: Context) -> ShortcutListScrollDiagnosticsView {
        let view = ShortcutListScrollDiagnosticsView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: ShortcutListScrollDiagnosticsView, context: Context) {}

    static func dismantleNSView(_ nsView: ShortcutListScrollDiagnosticsView, coordinator: ()) {
        nsView.detach()
    }
}

// MARK: - NSView subclass

/// Zero-size hidden view that resolves its enclosing `NSScrollView` and, when
/// `CMUX_SCROLL_DIAG=1` is set, streams frame/bounds samples to a CSV file.
final class ShortcutListScrollDiagnosticsView: NSView {
    // Observer tokens and the FileHandle are only ever assigned/read on the
    // main thread. `nonisolated(unsafe)` keeps deinit (nonisolated) legal under
    // Swift 6 without weakening the type — same pattern as
    // SidebarScrollViewResolverView.
    private nonisolated(unsafe) var frameObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var boundsObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var fileHandle: FileHandle?

    override init(frame frameRect: NSRect) {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        fileHandle?.closeFile()
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Deferred one main-actor hop so the view hierarchy settles before
        // enclosingScrollView is resolved — mirrors SidebarScrollViewResolverView.
        Task { @MainActor [weak self] in
            guard let self, self.window != nil else { return }
            self.attach(to: self.enclosingScrollView)
        }
    }

    // MARK: - Attach / Detach

    /// Wires frame/bounds observers to `scrollView` and opens the CSV file.
    /// No-ops if the env gate is not set or `scrollView` is `nil`.
    func attach(to scrollView: NSScrollView?) {
        guard ProcessInfo.processInfo.environment["CMUX_SCROLL_DIAG"] == "1",
              let scrollView
        else { return }

        let path = ProcessInfo.processInfo.environment["CMUX_SCROLL_DIAG_FILE"]
            ?? "/tmp/cmux-scroll-diag.csv"

        // Create-or-truncate the file so each run starts clean.
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        fileHandle = handle
        try? handle.write(contentsOf: Data("# t,event,docH,clipOriginY\n".utf8))

        // Enable change notifications.
        let docView = scrollView.documentView
        docView?.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Frame changes on documentView — captures the height-dip transient.
        // `MainActor.assumeIsolated` is safe because we pass `queue: .main`;
        // the block runs synchronously on the main thread so the assertion always
        // holds. Using an async Task hop instead would risk missing the ~10ms
        // document-height transient that is the bug being measured.
        if let docView {
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: docView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.log(event: "frame", scrollView: scrollView)
                }
            }
        }

        // Bounds changes on contentView (clip) — captures scroll-position jumps.
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView else { return }
                self.log(event: "bounds", scrollView: scrollView)
            }
        }
    }

    /// Removes all observers and closes the file handle.
    func detach() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        frameObserver = nil
        boundsObserver = nil
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: - Logging

    private func log(event: String, scrollView: NSScrollView) {
        guard let handle = fileHandle else { return }
        let t = ProcessInfo.processInfo.systemUptime
        let docH = scrollView.documentView?.frame.height ?? 0
        let clipY = scrollView.contentView.bounds.origin.y
        let line = "\(t),\(event),\(docH),\(clipY)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
#endif
