import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief chat's zoom (Cmd-= / Cmd-- / Cmd-0 on Home): the transcript lays out at its frame's
/// size over the zoom and the view's bounds draw it magnified, with every row bitmap at the
/// window's scale times the zoom, so the larger text stays sharp. Before, nothing zoomed it.
@MainActor @Suite(.serialized) struct HomeZoomTests {
    @Test func zoomMagnifiesThePaneAndDrawsItAtTheZoomedScale() async throws {
        let rig = try await HomeChatRig(history: 40, width: 600)
        defer { rig.stop() }
        let view = rig.view, host = view.controller.host
        let demo = try #require(view.controller.demo)
        let backing = try #require(host.window?.backingScaleFactor)
        let header = view.headerHeight, fieldTop = view.fieldTop
        #expect(demo.renderScale == backing)

        var fieldMoves = 0
        view.onFieldTopChange = { fieldMoves += 1 }
        view.zoom = 1.5
        // The zoom lays the host out at once and tells the host page: what it keeps above the field (the
        // first-run panel, a notice) reads the zoomed field's place before any later layout pass.
        let zoomedFieldTop = view.fieldTop
        #expect(fieldMoves >= 1)
        rig.frame()
        #expect(view.fieldTop == zoomedFieldTop)
        #expect(view.frame.size == CGSize(width: 600, height: 900))
        #expect(view.bounds.size == CGSize(width: 400, height: 600))
        // The rows lay out in the narrower design width, at 1.5 device pixels per window pixel.
        #expect(host.frame.size == CGSize(width: 400, height: 600))
        #expect(demo.bounds.width == 400)
        #expect(demo.renderScale == backing * 1.5)
        // A design point lands 1.5 times as far in the window (the view is flipped, the window is not).
        #expect(view.convert(NSPoint(x: 200, y: 300), to: nil) == NSPoint(x: 300, y: 450))
        // Geometry for the first-run panel is in the view's frame points.
        #expect(view.headerHeight == header * 1.5)
        #expect(view.fieldTop == demo.fieldTop * 1.5)

        // A resize keeps the zoom.
        rig.resize(width: 900)
        #expect(view.bounds.size == CGSize(width: 600, height: 600))
        #expect(host.frame.size == CGSize(width: 600, height: 600))

        view.zoom = 9  // clamped
        #expect(view.zoom == 3)

        view.zoom = 1
        rig.resize(width: 600)
        #expect(view.bounds.size == view.frame.size)
        #expect(demo.renderScale == backing)
        #expect(view.headerHeight == header)
        #expect(view.fieldTop == fieldTop)
    }

    /// A canvas camera scales the pane's ancestors (their bounds), not the chat's zoom: the field's text keeps the
    /// window's scale at zoom 1 and the window's scale times the zoom when zoomed, whatever the camera does.
    @Test func aCanvasCameraDoesNotChangeTheFieldTextScale() async throws {
        let rig = try await HomeChatRig(history: 10, width: 600)
        defer { rig.stop() }
        let view = rig.view
        let field = try #require(view.controller.demo?.compose.textView.view)
        let backing = try #require(rig.window.backingScaleFactor as CGFloat?)
        let camera = NSView(frame: view.frame)
        rig.window.contentView = camera
        camera.addSubview(view)
        camera.setBoundsSize(NSSize(width: view.frame.width / 2, height: view.frame.height / 2))  // the camera at 200%
        field.applyScale()
        #expect(field.layer?.contentsScale == backing)

        view.zoom = 1.5
        field.applyScale()
        #expect(field.layer?.contentsScale == backing * 1.5)
    }
}
