import AppKit
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
/// Popup surfaces (`rb.surface.show/update/hide`): each shows as its own
/// view over the page at its CSS anchor, decodes its own stream, sends
/// pointer input named by its surface id, and goes on hide.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserSurfacesTests {
    static let show = RemoteRdJSON.object([
        "t": .string("rb.surface.show"), "surface": .int(7), "stream": .int(2), "kind": .string("page_popup"),
        "anchor": .object(["x": .int(10), "y": .double(20.5), "width": .int(120), "height": .int(80)]),
        "width": .int(240), "height": .int(160),
    ])

    @Test func surfaceMessagesParseAndOtherBodiesDoNot() {
        #expect(RbSurfaceMessage(Self.show) == .show(
            surface: 7, stream: 2, kind: "page_popup", anchor: CGRect(x: 10, y: 20.5, width: 120, height: 80), pixelWidth: 240, pixelHeight: 160))
        #expect(RbSurfaceMessage(.object([
            "t": .string("rb.surface.update"), "surface": .int(7),
            "anchor": .object(["x": .int(1), "y": .int(2), "width": .int(3), "height": .int(4)]), "width": .int(6), "height": .int(8),
        ])) == .update(surface: 7, anchor: CGRect(x: 1, y: 2, width: 3, height: 4), pixelWidth: 6, pixelHeight: 8))
        #expect(RbSurfaceMessage(.object(["t": .string("rb.surface.hide"), "surface": .int(7)])) == .hide(surface: 7))
        #expect(RbSurfaceMessage(.object(["t": .string("rb.page"), "url": .string("u")])) == nil)
        #expect(RbSurfaceMessage(.object(["t": .string("rb.surface.show"), "surface": .int(7)])) == nil)
    }

    @Test func aShownSurfaceSitsOverThePageAtItsAnchorUntilHidden() throws {
        let (surfaces, page, streams, _) = Self.make()
        surfaces.apply(try #require(RbSurfaceMessage(Self.show)))
        let view = try #require(surfaces.view(of: 7))
        #expect(view.superview === page)
        #expect(view.frame == CGRect(x: 10, y: 20.5, width: 120, height: 80))
        #expect(streams.requested == [2])

        surfaces.apply(.update(surface: 7, anchor: CGRect(x: 40, y: 50, width: 60, height: 70), pixelWidth: 120, pixelHeight: 140))
        #expect(view.frame == CGRect(x: 40, y: 50, width: 60, height: 70))

        surfaces.apply(.hide(surface: 7))
        #expect(surfaces.view(of: 7) == nil)
        #expect(view.superview == nil)
        #expect(!page.subviews.contains(view))
    }

    /// CEF API 21 kinds: a datalist/autofill list and an extension popup are
    /// child views over the page like a page popup, each on its own stream.
    @Test(arguments: ["autofill", "extension_popup"])
    func viewsSurfaceKindsShowAsChildViewsAtTheirAnchor(kind: String) throws {
        let (surfaces, page, streams, _) = Self.make()
        let body = RemoteRdJSON.object([
            "t": .string("rb.surface.show"), "surface": .int(11), "stream": .int(4), "kind": .string(kind),
            "anchor": .object(["x": .int(8), "y": .int(40), "width": .int(180), "height": .int(90)]),
            "width": .int(360), "height": .int(180),
        ])
        surfaces.apply(try #require(RbSurfaceMessage(body)))
        let view = try #require(surfaces.view(of: 11))
        #expect(view.superview === page)
        #expect(view.frame == CGRect(x: 8, y: 40, width: 180, height: 90))
        #expect(streams.requested == [4])
        surfaces.apply(.hide(surface: 11))
        #expect(surfaces.view(of: 11) == nil)
    }

    @Test func closingTheSessionRemovesEverySurface() throws {
        let (surfaces, page, _, _) = Self.make()
        surfaces.apply(try #require(RbSurfaceMessage(Self.show)))
        surfaces.apply(.show(surface: 8, stream: 3, kind: "bubble", anchor: CGRect(x: 0, y: 0, width: 5, height: 5), pixelWidth: 10, pixelHeight: 10))
        #expect(surfaces.surfaceIDs == [7, 8])
        surfaces.closeAll()
        #expect(surfaces.surfaceIDs.isEmpty)
        #expect(page.subviews.allSatisfy { !($0 is RemoteBrowserContentView) })
    }

    @Test func pointerInputOnASurfaceNamesItAndUsesItsOwnCoordinates() throws {
        let (surfaces, _, _, sent) = Self.make()
        surfaces.apply(try #require(RbSurfaceMessage(Self.show)))
        surfaces.sendPointer(RemoteBrowserTabTests.mouse(.leftMouseDown, at: .zero, [], clicks: 1), at: CGPoint(x: 12, y: 34), surface: 7)
        surfaces.sendPointer(RemoteBrowserTabTests.mouse(.leftMouseUp, at: .zero, [], clicks: 1), at: CGPoint(x: 12, y: 34), surface: 7)
        #expect(sent.events.count == 2)
        guard case let .object(down)? = sent.events.first?.json else { Issue.record("no event"); return }
        #expect(down["e"] == .string("pointer"))
        #expect(down["surface"] == .int(7))
        #expect(down["kind"] == .string("down"))
        #expect(down["x"] == .double(12))
        #expect(down["y"] == .double(34))
        #expect(sent.events.allSatisfy { $0.mustDeliver })
    }

    @Test func pointerInputForAHiddenSurfaceIsDropped() {
        let (surfaces, _, _, sent) = Self.make()
        surfaces.sendPointer(RemoteBrowserTabTests.mouse(.leftMouseDown, at: .zero, [], clicks: 1), at: .zero, surface: 9)
        #expect(sent.events.isEmpty)
    }

    // MARK: Fixtures

    private static func make() -> (RemoteBrowserSurfaces, RemoteBrowserContentView, StreamRecorder, InputRecorder) {
        let page = RemoteBrowserPane(source: MockRemoteStreamSource(width: 64, height: 64)).view
        page.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let streams = StreamRecorder()
        let sent = InputRecorder()
        let surfaces = RemoteBrowserSurfaces(
            page: page,
            source: { stream in
                streams.requested.append(stream)
                return MockRemoteStreamSource(width: 32, height: 32)
            },
            send: { json, mustDeliver in sent.events.append((json, mustDeliver)) })
        return (surfaces, page, streams, sent)
    }
}

@MainActor
private final class StreamRecorder {
    var requested: [UInt16] = []
}

@MainActor
private final class InputRecorder {
    var events: [(json: RemoteRdJSON, mustDeliver: Bool)] = []
}
#endif
