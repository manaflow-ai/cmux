import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import WebKit

/// Rebinding support for the current pooled page bridge.
extension PageWebView {
    /// Retargets a pooled view to another bundled React page.
    ///
    /// Rebinding resets the router before the new descriptor is admitted, so every subscription and
    /// in-flight page operation owned by the old document is cancelled. Another page loads its own
    /// document. The same page keeps its loaded document when that document acknowledges the claim
    /// (``claimDocument(documentAttributes:)``): a parked spare held its reads, so it reads through
    /// the new routes now. A document that already ran against other routes would keep that state
    /// with no live subscription (cx-o9kv), so it refuses and reloads.
    @discardableResult
    func retarget(descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil,
                  documentAttributes: [String: String] = [:], surface: SurfaceKind? = nil,
                  dynamicResources: (any PageDynamicResourceSource)? = nil) -> Bool {
        guard isPooled, PageServedHosts.pooledDescriptors.contains(descriptor), PageWebView.servedRoot(for: descriptor) != nil else {
            return false
        }
        router.rebind(descriptor: descriptor, routes: routes)
        self.descriptor = descriptor
        self.dynamicResources = dynamicResources
        themeSurface = surface
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        touched = false
        reinstallPageScripts(documentAttributes: documentAttributes)
        installDocumentStartTheme()
        let target = descriptor.url(route: route)
        guard let current = webView.url, Self.sameDocumentURL(current, target) else {
            noteLoadedClaim()
            loaded = false
            webView.load(URLRequest(url: target))
            return true
        }
        if loaded {
            claimDocument(documentAttributes: documentAttributes)
        } else {
            noteLoadedClaim()
            reloadDocument()
        }
        return true
    }

    /// True when `a` and `b` differ at most in their fragment (a load would not replace the document).
    nonisolated static func sameDocumentURL(_ a: URL, _ b: URL) -> Bool {
        var left = URLComponents(url: a, resolvingAgainstBaseURL: false)
        var right = URLComponents(url: b, resolvingAgainstBaseURL: false)
        left?.fragment = nil
        right?.fragment = nil
        return left?.url == right?.url
    }

    /// Clears the router before an untouched host is parked for another claim.
    func resetPooledPage() async {
        router.rebind(descriptor: descriptor, routes: [])
        dynamicResources = nil
        route = nil
        countsTouches = false
        touched = false
        guard loaded else { return }
        let script = """
        localStorage.clear();
        sessionStorage.clear();
        if (globalThis.caches) {
          for (const key of await caches.keys()) await caches.delete(key);
        }
        if (indexedDB?.databases) {
          for (const database of await indexedDB.databases()) {
            if (!database.name) continue;
            await new Promise((resolve) => {
              const request = indexedDB.deleteDatabase(database.name);
              request.onsuccess = request.onerror = request.onblocked = () => resolve();
            });
          }
        }
        return true;
        """
        _ = try? await webView.callAsyncJavaScript(script, contentWorld: .page)
    }
}
