import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import WebKit

/// Rebinding support for the current pooled page bridge.
extension PageWebView {
    /// Retargets a pooled view to another bundled React page.
    ///
    /// Rebinding resets the router before the new descriptor is admitted, so every subscription and
    /// in-flight page operation owned by the old document is cancelled. A host already showing the
    /// requested descriptor keeps its document and only changes its routes and fragment.
    @discardableResult
    func retarget(descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil,
                  documentAttributes: [String: String] = [:], surface: SurfaceKind? = nil,
                  dynamicResources: (any PageDynamicResourceSource)? = nil) -> Bool {
        guard isPooled, PageServedHosts.pooledDescriptors.contains(descriptor), servedRoot(for: descriptor) != nil else {
            return false
        }
        let sameDocument = self.descriptor == descriptor && loaded
        router.rebind(descriptor: descriptor, routes: routes)
        self.descriptor = descriptor
        self.dynamicResources = dynamicResources
        themeSurface = surface
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        touched = false
        if !sameDocument {
            reinstallPageScripts(documentAttributes: documentAttributes)
            loaded = false
            webView.load(URLRequest(url: descriptor.url(route: route)))
        } else if let route {
            open(route: route)
        }
        return true
    }

    /// Clears the router before an untouched host is parked for another claim.
    func resetPooledPage() {
        router.rebind(descriptor: descriptor, routes: [])
        dynamicResources = nil
        route = nil
        countsTouches = false
        touched = false
    }
}
