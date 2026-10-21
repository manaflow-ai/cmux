// The commands both engines run as a script in the page's main world.

extension WebDevToolsCommand {
    /// The page script that runs the command, or nil when it is not a
    /// script. Clear Console clears the console; Disable CSS turns every
    /// style sheet and `style` attribute off, and on again on the next run
    /// (the page's root element remembers the state, so a new document
    /// starts with CSS on). Both return a Boolean: whether the mode is on.
    public nonisolated var pageScript: String? {
        switch self {
        case .clearConsole:
            "console.clear(); false"
        case .toggleCSS:
            """
            (() => {
              const root = document.documentElement;
              const off = !root.hasAttribute('data-cmux-css-off');
              for (const sheet of document.styleSheets) { try { sheet.disabled = off; } catch (e) {} }
              if (off) {
                for (const el of document.querySelectorAll('[style]')) {
                  el.setAttribute('data-cmux-style', el.getAttribute('style'));
                  el.removeAttribute('style');
                }
                root.setAttribute('data-cmux-css-off', '');
              } else {
                for (const el of document.querySelectorAll('[data-cmux-style]')) {
                  el.setAttribute('style', el.getAttribute('data-cmux-style'));
                  el.removeAttribute('data-cmux-style');
                }
                root.removeAttribute('data-cmux-css-off');
              }
              return off;
            })()
            """
        default:
            nil
        }
    }
}
