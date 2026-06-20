import Foundation

/// JavaScript installed before page scripts run in HTML custom sidebars.
enum CustomSidebarWebBootstrapScript {
    static let source = """
    (() => {
      const ensure = () => {
        const root = window.cmux || {};
        window.cmux = root;
        root.sidebar = root.sidebar || {};
        root.postAction = (action) => {
          window.webkit?.messageHandlers?.cmuxSidebarAction?.postMessage(action);
        };
        return root;
      };
      ensure();
    })();
    """
}
