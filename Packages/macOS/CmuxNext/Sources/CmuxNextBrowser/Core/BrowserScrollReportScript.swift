import Foundation

/// Reports the main frame's scroll position once its scrolling settles, from a script in its own
/// isolated world, so the tab's saved history has it before a crash (``BrowserScrollReport``).
/// Both engines run it: WebKit through a message handler, Chromium with the renderer paths
/// (fork API 29) through its page channel. A load at the top reports nothing; a report repeats
/// only when the position changed.
nonisolated struct BrowserScrollReportScript {
    static let channel = "cmuxScrollReport"
    static let world = "cmuxScrollReport"
    /// How long scrolling must stop before the position is reported: a fling or a held arrow key
    /// reports once, at its end.
    static let settleMilliseconds = 400

    /// The script, with `post` the statement that reports (it may use `y`, a whole number) and
    /// `ready` the expression that says the report channel exists.
    static func source(post: String, ready: String) -> String {
        """
        (() => {
          let timer = 0, last = 0;
          const send = () => {
            timer = 0;
            const y = Math.max(0, Math.round(window.scrollY || 0));
            if (y === last) return;
            last = y;
            if (\(ready)) { \(post); }
          };
          window.addEventListener('scroll', () => {
            if (timer) clearTimeout(timer);
            timer = setTimeout(send, \(settleMilliseconds));
          }, { passive: true });
        })();
        """
    }
}
