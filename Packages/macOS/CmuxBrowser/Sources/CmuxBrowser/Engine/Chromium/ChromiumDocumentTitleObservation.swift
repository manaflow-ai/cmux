/// Defines Chromium's isolated document-title observation bridge.
struct ChromiumDocumentTitleObservation {
    private let bindingName = "__cmuxChromiumTitleChanged"
    private let worldName = "cmux.browser.title-observation"

    /// Parameters that expose the native binding only in cmux's isolated world.
    var bindingParameters: [String: CDPJSONValue] {
        [
            "name": .string(bindingName),
            "executionContextName": .string(worldName),
        ]
    }

    /// Parameters that install the title observer before page scripts run.
    var scriptParameters: [String: CDPJSONValue] {
        [
            "source": .string(scriptSource),
            "worldName": .string(worldName),
        ]
    }

    /// Decodes a title delivered through the isolated Runtime binding.
    func title(from event: CDPEvent) -> String? {
        guard event.method == "Runtime.bindingCalled",
              event.parameters["name"]?.stringValue == bindingName else { return nil }
        return event.parameters["payload"]?.stringValue
    }

    private var scriptSource: String {
        """
        (() => {
          if (window !== window.top || globalThis.__cmuxChromiumTitleObserverInstalled === true) {
            return;
          }
          globalThis.__cmuxChromiumTitleObserverInstalled = true;

          let lastTitle;
          let observedTitleElement = null;
          const reportTitle = () => {
            const title = document.title || '';
            if (title === lastTitle) return;
            lastTitle = title;
            globalThis.__cmuxChromiumTitleChanged(title);
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
