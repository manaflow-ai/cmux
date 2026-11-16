package import AppKit

/// Applies `RemoteCursorPresentation` to one pane's views: the overlay on the video and
/// the cursor the local pointer wears on the input surface. The pane feeds it the remote
/// cursor; the surface tells it when the pointer moved, entered, left or the mode changed.
@MainActor
package final class RemoteCursorCoordinator {
    private weak var video: RemoteVideoView?
    private weak var capture: RemoteInputCaptureView?
    private var cursor: RemoteCursorState?
    /// The NSCursor of the last remote shape at the last scale.
    private var worn: (id: UInt32, scale: CGFloat, cursor: NSCursor)?
    package private(set) var presentation = RemoteCursorPresentation.none

    init(video: RemoteVideoView, capture: RemoteInputCaptureView) {
        self.video = video
        self.capture = capture
        capture.onPointerChange = { [weak self] in self?.update() }
    }

    /// The latest remote cursor (nil: the session has no cursor metadata).
    package func setRemoteCursor(_ cursor: RemoteCursorState?) {
        self.cursor = cursor
        update()
    }

    /// Re-decides after a layout or scale change.
    package func update() {
        guard let video, let capture else { return }
        let geometry = video.geometry
        let echoes = cursor.map { capture.echo.matches($0.position, at: .now) } ?? false
        let inFrame = cursor.map { geometry?.containsStreamPixel($0.position.x, $0.position.y) ?? false } ?? false
        let next = RemoteCursorPresentation.decide(
            cursor: cursor, control: capture.controller.isActive, pointerInImage: capture.pointerInImage,
            echoesLocalPointer: echoes, inFrame: inFrame)
        presentation = next
        video.setRemoteCursor(cursor, drawsOverlay: next.drawsOverlay)
        switch next.local {
        case .system: capture.localCursor = nil
        case .hidden: capture.localCursor = Self.blank
        case .remoteShape: capture.localCursor = cursor?.shape.flatMap { wear($0, geometry: geometry) }
        }
    }

    /// The remote shape as an NSCursor at the picture's scale (one stream pixel shows as
    /// `pointsPerStreamPixel` points), so it is as large as the remote screen shows it.
    private func wear(_ shape: RemoteCursorShape, geometry: RemoteViewGeometry?) -> NSCursor? {
        guard let scale = geometry?.pointsPerStreamPixel, scale > 0 else { return nil }
        if let worn, worn.id == shape.id, worn.scale == scale { return worn.cursor }
        let size = NSSize(width: shape.pixelSize.width * scale, height: shape.pixelSize.height * scale)
        let image = NSImage(cgImage: shape.image, size: size)
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: shape.hotSpot.x * scale, y: shape.hotSpot.y * scale))
        worn = (shape.id, scale, cursor)
        return cursor
    }

    /// The remote hid its cursor: so does the local pointer over the picture.
    private static let blank: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()
}
