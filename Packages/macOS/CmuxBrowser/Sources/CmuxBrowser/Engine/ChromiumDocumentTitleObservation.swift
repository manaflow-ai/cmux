/// Bridges page-title mutations from Chromium's renderer into CDP events.
struct ChromiumDocumentTitleObservation: Sendable {
    private let bindingName = "__cmuxChromiumTitleChanged"
    private let worldName = "cmux.browser.title-observation"

    /// Parameters that expose the binding only in cmux's isolated execution world.
    var bindingParameters: CDPValue {
        .object([
            "name": .string(bindingName),
            "executionContextName": .string(worldName),
        ])
    }

    /// Parameters that install the observer before page scripts execute.
    var scriptParameters: CDPValue {
        .object([
            "source": .string(scriptSource),
            "worldName": .string(worldName),
        ])
    }

    /// Extracts a title from a matching `Runtime.bindingCalled` event.
    func title(from event: CDPEvent) -> String? {
        guard event.method == "Runtime.bindingCalled",
              event.params?["name"]?.stringValue == bindingName else {
            return nil
        }
        return event.params?["payload"]?.stringValue
    }

    private var scriptSource: String {
        """
        (() => {
          if (window !== window.top || globalThis.__cmuxChromiumTitleObserverInstalled === true) {
            return;
          }
          globalThis.__cmuxChromiumTitleObserverInstalled = true;

          const binding = globalThis.__cmuxChromiumTitleChanged;
          if (typeof binding !== 'function') return;
          let lastTitle;
          let observedTitleElement = null;
          const reportTitle = () => {
            const title = document.title || '';
            if (title === lastTitle) return;
            lastTitle = title;
            binding(title);
          };
          const titleObserver = new MutationObserver(reportTitle);
          const observeTitleElement = () => {
            const titleElement = document.querySelector('head > title');
            if (titleElement !== observedTitleElement) {
              titleObserver.disconnect();
              observedTitleElement = titleElement;
              if (titleElement) {
                titleObserver.observe(titleElement, {
                  childList: true,
                  characterData: true,
                  subtree: true
                });
              }
            }
            reportTitle();
          };
          const headObserver = new MutationObserver(observeTitleElement);
          const attach = () => {
            if (!document.head) return false;
            headObserver.observe(document.head, { childList: true });
            observeTitleElement();
            return true;
          };

          if (!attach()) {
            document.addEventListener('readystatechange', attach, { once: true });
            document.addEventListener('DOMContentLoaded', attach, { once: true });
          }
        })()
        """
    }
}
