import AppKit
public import Foundation

/// Page file choosers in host mode (feature `chromiumHostFileDialogs`): the
/// host sends each FILE_DIALOG, cmux shows its own panel on the page's window, and the chosen files go
/// back as absolute paths (`cmux_shim_file_dialog_answer`), so Chromium's own panel never opens in
/// the host. Chrome does the same across its app shim: the panel runs in the process that owns the
/// window (components/remote_cocoa/app_shim/select_file_dialog_bridge.mm) and only the chosen paths
/// cross back (components/remote_cocoa/common/select_file_dialog.mojom, `Show` replies
/// `array<mojo_base.mojom.FilePath>`). Each chooser is answered exactly once.
final class ChromiumHostFiles {
    /// Sends an answer to Chromium: `cmux_shim_file_dialog_answer` in the app, a recorder in tests.
    typealias Answer = (_ dialog: Int32, _ multiple: Int32, _ paths: String?) -> Void

    private struct Asking {
        let browser: Int32
        let multiple: Int32
        let answer: Answer
    }

    private let panels: any ChromiumFileDialogAnswering
    /// The choosers waiting for the person, by Chromium's dialog id (never reused).
    private var asking: [Int32: Asking] = [:]
    /// Choosers asked and answered so far (`debug.cef` `host_file_dialogs`).
    private(set) var asked = 0
    private(set) var answered = 0

    init(panels: any ChromiumFileDialogAnswering) {
        self.panels = panels
    }

    /// The choosers waiting for the person now.
    var waiting: Int { asking.count }

    /// Shows the picker for `browser`'s chooser `dialog` on `window`; `answer` gets the person's choice.
    func ask(_ dialog: Int32, browser: Int32, request: ChromiumFileDialogRequest, window: NSWindow?,
             answer: @escaping Answer) {
        asked += 1
        guard asking[dialog] == nil else { return answer(dialog, request.multiple, nil) }
        asking[dialog] = Asking(browser: browser, multiple: request.multiple, answer: answer)
        panels.answerFileDialog(dialog, request: request, window: window) { [weak self] urls in
            self?.finish(dialog, with: urls)
        }
    }

    /// Answers the newest waiting chooser with `urls` (nil cancels) and takes its picker down, as a
    /// person's choice in it would (`debug.cef` `file_dialog_choose`, chromium-host-bench.py's
    /// file_picker row). False when none waits.
    func answerNewest(with urls: [URL]?) -> Bool {
        guard let dialog = asking.keys.max() else { return false }
        finish(dialog, with: urls)
        panels.endFileDialog(dialog)
        return true
    }

    /// Chromium closed `browser` and cancelled its choosers itself: their pickers go, unanswered;
    /// another browser's chooser keeps its picker, even on the same window.
    func browserClosed(_ browser: Int32) {
        for (dialog, entry) in asking where entry.browser == browser {
            asking[dialog] = nil
            panels.endFileDialog(dialog)
        }
    }

    /// The host ended: every chooser went with it.
    func hostEnded() {
        for browser in Set(asking.values.map(\.browser)) { browserClosed(browser) }
    }

    /// Answers `dialog` once; a later answer of it (its picker's own completion after
    /// ``answerNewest(with:)``) is ignored.
    private func finish(_ dialog: Int32, with urls: [URL]?) {
        guard let entry = asking.removeValue(forKey: dialog) else { return }
        answered += 1
        entry.answer(dialog, entry.multiple, ChromiumFileDialogRequest.paths(urls))
    }
}

extension CEFRuntime {
    /// Host mode, at the start: the host sends page file choosers to cmux (FILE_DIALOG) when the source
    /// gave a picker (``CEFHostStart/files``); ordered before any page op.
    func answerHostFileDialogs(_ shim: CEFShimLibrary) {
        guard hostStart?.files != nil else { return }
        shim.setFileDialogs(1)
    }

    /// FILE_DIALOG: cmux's picker on the page's window answers it. Without one (in process, or the
    /// feature off, where the shim sends none), it is cancelled at once, so a page never waits.
    func fileDialogAsked(_ dialog: Int32, browser: Int32, request: ChromiumFileDialogRequest) {
        guard let files = hostStart?.files else {
            _ = shim?.fileDialogAnswer(dialog, 0, nil)
            return
        }
        files.ask(dialog, browser: browser, request: request, window: tabsByBrowser[browser]?.host.hostView.window) { [weak self] dialog, multiple, paths in
            // The answer's result is never read: 0 only says Chromium already ended the chooser.
            _ = self?.shim?.fileDialogAnswer(dialog, multiple, paths)
        }
    }
}

/// `debug.cef` `host_file_dialogs`: the choosers cmux answered for the host's pages.
public struct CEFHostFileDialogReport: Equatable, Sendable {
    public let asked: Int
    public let answered: Int
    /// Pickers showing now.
    public let waiting: Int
}

extension CEFEngine {
    /// The host's page file choosers so far; nil when cmux does not answer them (in process, or
    /// feature `chromiumHostFileDialogs` off).
    public var hostFileDialogs: CEFHostFileDialogReport? {
        CEFRuntime.shared.hostStart?.files.map { CEFHostFileDialogReport(asked: $0.asked, answered: $0.answered, waiting: $0.waiting) }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Answers the newest waiting page file chooser with `urls` (nil cancels), as a choice in its
    /// picker would. False when none waits.
    public func answerHostFileDialog(with urls: [URL]?) -> Bool {
        CEFRuntime.shared.hostStart?.files?.answerNewest(with: urls) ?? false
    }
    #endif
}
