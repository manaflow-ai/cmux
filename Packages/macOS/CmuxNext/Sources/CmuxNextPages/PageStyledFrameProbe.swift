import CmuxNextDesign
import Foundation
import WebKit

/// The first frame a page document drew styled, for the WebKit against Chromium measurements
/// (`debug.agent_pane readiness`'s `first_styled_frame_ms`, beside `first_contentful_paint_ms`).
/// Styled: the shared theme is applied (`window.cmuxTheme.current`, WebTheme), the parser is past
/// `<head>` (its inline styles apply), every linked stylesheet has loaded, and the root's text is
/// not transparent: the frame a Chromium page never reached while its document-start theme threw
/// on a missing root (#24037).
///
/// A document-start script checks once per animation frame (a read of the root's computed style;
/// nothing per row) and keeps that frame's `requestAnimationFrame` time, in ms on the page clock,
/// in `window.__cmuxStyledFrame` (null until then). Stop condition: the first styled frame, or a
/// frame 10 s after the document started. Cleanup: none is left; it registers no observer or
/// listener, and the frame chain ends with its last check. Installed only in DEBUG automation
/// launches (``WindowDrawPolicy/isAutomationLaunch(_:)``), the benches' launches, never in Release.
enum PageStyledFrameProbe {
    static let script = """
    (() => {
      if (window.__cmuxStyledFrame !== undefined) return;
      window.__cmuxStyledFrame = null;
      const until = performance.now() + 10000;
      const styled = () => {
        const root = document.documentElement;
        if (!root || !document.body || !window.cmuxTheme || !window.cmuxTheme.current) return false;
        for (const link of document.querySelectorAll('link[rel~="stylesheet"]')) if (!link.sheet) return false;
        return getComputedStyle(root).color !== 'rgba(0, 0, 0, 0)';
      };
      const check = (frame) => {
        if (styled()) { window.__cmuxStyledFrame = frame; return; }
        if (frame < until) requestAnimationFrame(check);
      };
      requestAnimationFrame(check);
    })();
    """

    /// Adds the script to `controller` in a DEBUG automation launch. A Chromium page gets it with
    /// the controller's other scripts (``PageChromiumDocumentScripts``).
    static func install(in controller: WKUserContentController,
                        environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        guard WindowDrawPolicy.isAutomationLaunch(environment) else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        #endif
    }
}
