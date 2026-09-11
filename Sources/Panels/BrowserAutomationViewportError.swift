enum BrowserAutomationViewportError: Error {
    case attachedBrowserInspector
    case elementFullscreen
    case renderGeometryTooLarge(requestedPageZoom: Double, maximumPageZoom: Double)
}
