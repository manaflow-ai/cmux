import AppKit
import CmuxBrowser
import Foundation

enum BrowserDesignModeSupport {
    static func decodeSnapshot(_ value: Any?) throws -> BrowserDesignModeSnapshot {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw BrowserDesignModeError.invalidRuntimeResponse
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(BrowserDesignModeSnapshot.self, from: data)
    }

    static func decodeAnnotationCaptureRequest(
        _ value: Any?
    ) throws -> BrowserDesignModeAnnotationCaptureRequest {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw BrowserDesignModeError.invalidRuntimeResponse
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(BrowserDesignModeAnnotationCaptureRequest.self, from: data)
    }

    static func captureMatches(
        before: BrowserDesignModeSnapshot,
        after: BrowserDesignModeSnapshot,
        beforeViewBounds: NSRect,
        afterViewBounds: NSRect
    ) -> Bool {
        before.enabled && after.enabled
            && before.revision == after.revision
            && before.selections == after.selections
            && beforeViewBounds == afterViewBounds
    }

    static func captureRect(
        selection: BrowserDesignModeRect,
        viewport: BrowserDesignModeViewport,
        viewBounds: NSRect
    ) -> NSRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let scaleX = viewBounds.width / viewport.width
        let scaleY = viewBounds.height / viewport.height
        let width = selection.width * scaleX
        let height = selection.height * scaleY
        return NSRect(
            x: viewBounds.minX + selection.x * scaleX,
            y: viewBounds.maxY - selection.y * scaleY - height,
            width: width,
            height: height
        )
    }

    static func productMessage(for error: any Error, fallback: String) -> String {
        if let error = error as? BrowserDesignModeError { return error.localizedDescription }
        if let error = error as? BrowserScreenshotError { return error.localizedDescription }
        return fallback
    }

    static func record(_ error: any Error, operation: String) {
#if DEBUG
        cmuxDebugLog("browser.designMode.\(operation).failed error=\(String(reflecting: error))")
#endif
    }
}
