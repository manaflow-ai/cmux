enum BrowserAutomationViewportError: Error {
    case attachedBrowserInspector
    case renderGeometryTooLarge(requestedPageZoom: Double, maximumPageZoom: Double)
}
