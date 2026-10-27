package import Foundation

// A cmux page as a web files change reaches it (``WebBundleHost``), in whichever engine shows it.
extension PageWebView: WebBundlePage {
    /// The script the safe point runs in a shown page (webviews/src/pages/shared/webSwap.ts).
    nonisolated static let bundleSwapScript = """
    const swap = window.cmuxWebSwap;
    if (!swap || typeof swap.hold !== "function") return "page.no-hook";
    const held = await swap.hold();
    return typeof held === "string" && held ? held : null;
    """

    package var bundleShown: Bool { engineVisible && bundleHasDocument }

    package var bundleHasDocument: Bool { !awaitsFirstShow && !isDiscarded && !isParkedSpare }

    package var bundleLoading: Bool { loadState.isLoading }

    package var bundleDocument: URL? { webKitEngine?.url ?? descriptor.url(route: route) }

    package func askBundleSwap() async -> String? {
        do {
            let held = try await callPageScript(Self.bundleSwapScript)
            return (held as? String).flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            return "page.error"
        }
    }

    package func reloadForBundle() {
        bundleStale = false
        reloadPage()
    }

    package func markBundleStale() {
        bundleStale = true
    }
}
