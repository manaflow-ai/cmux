import Foundation
import Testing
@testable import NativeMuxDemo

@Test
func decodesEveryNativeLayoutShape() throws {
    let data = Data(
        #"""
        {
          "machine":{"id":"machine_11111111111111111111111111111111"},
          "session":{"id":"session_22222222222222222222222222222222","name":"demo"},
          "workspaces":[{"id":"ws_33333333333333333333333333333333","name":"agents","index":0,"focused":true}],
          "screens":[{
            "id":"screen_44444444444444444444444444444444",
            "workspace_id":"ws_33333333333333333333333333333333",
            "name":"main","index":0,"focused":true,
            "layout":{
              "version":1,
              "screen_id":"screen_44444444444444444444444444444444",
              "active_pane_id":"pane_55555555555555555555555555555555",
              "zoomed_pane_id":null,
              "root":{"kind":"viewport","base_width":0.5,"columns":[
                {"column_id":"column_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","width":0.5,"root":{
                  "kind":"split","split_id":"split_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "direction":"horizontal","ratio":0.6,
                  "first":{"kind":"leaf","pane_id":"pane_55555555555555555555555555555555","tab_ids":["tab_77777777777777777777777777777777"],"active_tab_id":"tab_77777777777777777777777777777777"},
                  "second":{"kind":"stack","pane_ids":["pane_66666666666666666666666666666666"],"expanded_pane_id":"pane_66666666666666666666666666666666"}
                }}
              ]}
            }
          }],
          "panes":[
            {"id":"pane_55555555555555555555555555555555","screen_id":"screen_44444444444444444444444444444444","name":null,"focused":true,"zoomed":false},
            {"id":"pane_66666666666666666666666666666666","screen_id":"screen_44444444444444444444444444444444","name":null,"focused":false,"zoomed":false}
          ],
          "tabs":[{"id":"tab_77777777777777777777777777777777","pane_id":"pane_55555555555555555555555555555555","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"term_88888888888888888888888888888888"}],
          "terminals":[{"id":"term_88888888888888888888888888888888","tab_id":"tab_77777777777777777777777777777777","title":"shell","cols":80,"rows":24,"running":true,"lifecycle":"running"}],
          "browsers":[],
          "cursor":{"generation":"g","revision":"8"}
        }
        """#.utf8
    )

    let snapshot = try JSONDecoder().decode(ResourceSnapshot.self, from: data)
    #expect(snapshot.workspaces.first?.name == "agents")
    #expect(snapshot.screens.first?.layout.root.paneIDs.count == 2)
    guard case .viewport(let baseWidth, let columns) = snapshot.screens[0].layout.root else {
        Issue.record("viewport root was not decoded")
        return
    }
    #expect(baseWidth == 0.5)
    #expect(columns.count == 1)
    guard case .split(_, .horizontal, let ratio, _, let second) = columns[0].root else {
        Issue.record("split column was not decoded")
        return
    }
    #expect(ratio == 0.6)
    guard case .stack(let panes, let expanded) = second else {
        Issue.record("stack child was not decoded")
        return
    }
    #expect(panes == [expanded])
}

@Test
func resourceParametersPreserveMixedJSONTypes() throws {
    let encoded = try [
        "direction": JSONValue.string("right"),
        "viewport_width": .number(0.55),
        "columns": .integer(72),
        "enabled": .bool(true),
    ].encodedJSON()
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
    )
    #expect(object["direction"] as? String == "right")
    #expect(object["viewport_width"] as? Double == 0.55)
    #expect(object["columns"] as? Int == 72)
    #expect(object["enabled"] as? Bool == true)
}

@Test
func terminalGeometryIsBoundedAndNonzero() {
    #expect(terminalGeometry(width: 0, height: 0) == TerminalGeometry(cols: 1, rows: 1))
    #expect(terminalGeometry(width: 856, height: 424) == TerminalGeometry(cols: 100, rows: 24))
}
