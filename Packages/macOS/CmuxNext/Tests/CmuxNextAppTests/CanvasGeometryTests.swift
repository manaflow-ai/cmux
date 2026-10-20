import CmuxNextLayout
import CoreGraphics
import Testing

/// The canvas layout's pure geometry (plans/cmux-next/canvas-layout.md): the camera, placement
/// of panes that join, drags and their handles.
struct CanvasGeometryTests {
    let a: PaneID = "a", b: PaneID = "b", c: PaneID = "c"

    @Test func theCameraShowsItsCenterAndZoomsAboutAnAnchor() {
        let camera = CanvasCamera(center: CGPoint(x: 500, y: 300))
        #expect(camera.visibleRect(viewport: CGSize(width: 1000, height: 600)) == CGRect(x: 0, y: 0, width: 1000, height: 600))
        let closer = camera.zoomed(by: 2)
        #expect(closer.visibleRect(viewport: CGSize(width: 1000, height: 600)) == CGRect(x: 250, y: 150, width: 500, height: 300))
        // The anchor stays where it showed.
        let anchored = camera.zoomed(to: 2, around: CGPoint(x: 0, y: 0))
        #expect(anchored.visibleRect(viewport: CGSize(width: 1000, height: 600)).origin == .zero)
        #expect(CanvasCamera(zoom: 50).zoom == CanvasCamera.zoomRange.upperBound)
        #expect(CanvasCamera(zoom: 0).zoom == CanvasCamera.zoomRange.lowerBound)
    }

    @Test func aPanFollowsThePointerAtEveryZoom() {
        let camera = CanvasCamera(center: CGPoint(x: 100, y: 100), zoom: 2)
        #expect(camera.panned(byScreenDelta: CGSize(width: 40, height: -20)).center == CGPoint(x: 80, y: 110))
    }

    @Test func revealMovesTheLeastAndLeavesAShownRectAlone() {
        let camera = CanvasCamera(center: CGPoint(x: 500, y: 300))
        let viewport = CGSize(width: 1000, height: 600)
        #expect(camera.revealing(CGRect(x: 100, y: 100, width: 200, height: 200), viewport: viewport, margin: 16) == camera)
        let right = camera.revealing(CGRect(x: 1100, y: 100, width: 200, height: 200), viewport: viewport, margin: 16)
        #expect(right.visibleRect(viewport: viewport).maxX == 1316)
        #expect(right.center.y == 300)
    }

    @Test func fitShowsEveryPaneAndNeverMagnifies() {
        let viewport = CGSize(width: 1000, height: 600)
        let fit = CanvasCamera().fitting(CGRect(x: 0, y: 0, width: 4000, height: 1000), viewport: viewport, padding: 0)
        #expect(fit.zoom == 0.25)
        #expect(fit.visibleRect(viewport: viewport).contains(CGRect(x: 0, y: 0, width: 4000, height: 1000)))
        #expect(CanvasCamera().fitting(CGRect(x: 0, y: 0, width: 10, height: 10), viewport: viewport, padding: 0).zoom == 1)
    }

    @Test func aPaneThatJoinsGoesBesideTheFocusedPaneAndMovesNoOther() {
        var canvas = CanvasScreen(frames: [a: CGRect(x: 0, y: 0, width: 400, height: 300), b: CGRect(x: 416, y: 0, width: 400, height: 300)])
        let joined = canvas.reconcile(panes: [a, b, c], anchor: a)
        #expect(joined)
        let placed = canvas.frames[c]
        #expect(placed?.size == CGSize(width: 400, height: 300))
        #expect(placed == CGRect(x: 0, y: 316, width: 400, height: 300), "the right of a is taken by b, so c goes below a")
        #expect(canvas.frames[a] == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(canvas.order.last == c)
        let left = canvas.reconcile(panes: [a, c], anchor: a)
        #expect(left)
        #expect(canvas.frames[b] == nil && !canvas.order.contains(b))
        let again = canvas.reconcile(panes: [a, c], anchor: a)
        #expect(!again)
    }

    @Test func aDragMovesOrResizesWithinTheMinimum() {
        let drag = CanvasPaneDrag(pane: a, start: CGRect(x: 100, y: 100, width: 400, height: 300), edges: [], minimumSize: CGSize(width: 200, height: 100))
        #expect(drag.frame(translation: CGSize(width: 10, height: -5)) == CGRect(x: 110, y: 95, width: 400, height: 300))
        var resize = drag
        resize.edges = [.left, .bottom]
        #expect(resize.frame(translation: CGSize(width: 50, height: 20)) == CGRect(x: 150, y: 100, width: 350, height: 320))
        #expect(resize.frame(translation: CGSize(width: 1000, height: -1000)) == CGRect(x: 300, y: 100, width: 200, height: 100))
    }

    @Test func handlesSitInTheBandAroundAPane() {
        let canvas = CanvasScreen(frames: [a: CGRect(x: 100, y: 100, width: 400, height: 300)])
        let handles = CanvasHandles(canvas: canvas, thickness: 8)
        #expect(handles.hit(CGPoint(x: 300, y: 95))?.edges == [], "above the pane moves it")
        #expect(handles.hit(CGPoint(x: 95, y: 200))?.edges == [.left])
        #expect(handles.hit(CGPoint(x: 504, y: 404))?.edges == [.right, .bottom])
        #expect(handles.hit(CGPoint(x: 95, y: 95))?.edges == [.left, .top])
        #expect(handles.hit(CGPoint(x: 300, y: 200)) == nil, "inside the pane is the pane's")
        #expect(handles.hit(CGPoint(x: 20, y: 20)) == nil, "the empty canvas pans")
    }
}
