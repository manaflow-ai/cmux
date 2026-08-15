enum BrowserAutomationViewportError: Error {
    case attachedBrowserInspector
    case elementFullscreen
    case unsupportedEngine
    case renderGeometryTooLarge(requestedPageZoom: Double, maximumPageZoom: Double)
}
