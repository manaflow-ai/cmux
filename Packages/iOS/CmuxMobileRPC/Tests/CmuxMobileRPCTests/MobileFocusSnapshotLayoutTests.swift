import Foundation
import Testing

@testable import CmuxMobileRPC

@Suite struct MobileFocusSnapshotLayoutTests {
    @Test func focusSnapshotDecodesRectLayout() throws {
        let json = """
        {
          "workspace_id": "workspace-1",
          "workspace_ref": "w1",
          "workspace_title": "Main",
          "surface_id": "surface-1",
          "surface_ref": "s1",
          "surface_title": "Terminal",
          "surface_type": "terminal",
          "is_terminal": true,
          "layout": {
            "kind": "rects",
            "panes": [
              {
                "kind": "pane",
                "surface_id": "surface-1",
                "title": "Terminal",
                "surface_type": "terminal",
                "is_terminal": true,
                "focused": true,
                "rect": { "x": 0, "y": 0, "w": 0.5, "h": 1 }
              },
              {
                "kind": "pane",
                "surface_id": "surface-2",
                "title": "Browser",
                "surface_type": "browser",
                "is_terminal": false,
                "focused": false,
                "rect": { "x": 0.5, "y": 0, "w": 0.5, "h": 1 }
              }
            ]
          }
        }
        """

        let snapshot = try MobileFocusSnapshot.decode(Data(json.utf8))
        let layout = try #require(snapshot.layout)
        #expect(layout.kind == "rects")
        #expect(layout.panes.count == 2)
        #expect(layout.panes[0].surfaceID == "surface-1")
        #expect(layout.panes[0].isTerminal)
        #expect(layout.panes[0].focused)
        #expect(layout.panes[0].rect.width == 0.5)
        #expect(layout.panes[1].surfaceType == "browser")
        #expect(!layout.panes[1].isTerminal)
    }

    @Test func focusSnapshotToleratesMissingLayout() throws {
        let snapshot = try MobileFocusSnapshot.decode(
            Data(
                #"{"workspace_id":null,"workspace_ref":null,"workspace_title":null,"surface_id":null,"surface_ref":null,"surface_title":null,"surface_type":null,"is_terminal":false}"#.utf8
            )
        )

        #expect(snapshot.layout == nil)
        #expect(!snapshot.isTerminal)
    }
}
