package cmux

import (
	"encoding/json"
	"strings"
	"testing"
)

// A rows-v1 layout document: column 0 has two rows (row 2's row_id is its
// compat chain split), column 1 has one row and no rows field.
const layoutRowsDocument = `{"version":1,"screen_id":"screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
"active_pane_id":"pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","zoomed_pane_id":null,
"root":{"kind":"viewport","base_width":0.5,"columns":[
{"column_id":"split_cccccccccccccccccccccccccccccccc","width":0.5,
 "root":{"kind":"split","split_id":"split_dddddddddddddddddddddddddddddddd","direction":"vertical","ratio":0.6,
  "first":{"kind":"leaf","pane_id":"pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tab_ids":["tab_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]},
  "second":{"kind":"leaf","pane_id":"pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tab_ids":["tab_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}},
 "rows":[{"row_id":"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","height":600},{"row_id":"split_dddddddddddddddddddddddddddddddd","height":400}]},
{"column_id":"split_ffffffffffffffffffffffffffffffff","width":0.5,
 "root":{"kind":"leaf","pane_id":"pane_cccccccccccccccccccccccccccccccc","tab_ids":["tab_cccccccccccccccccccccccccccccccc"]}}]}}`

func TestLayoutDocumentRowsDecodeAndEncode(t *testing.T) {
	var document LayoutDocument
	if err := json.Unmarshal([]byte(layoutRowsDocument), &document); err != nil {
		t.Fatal(err)
	}
	viewport, ok := document.Root.(LayoutViewport)
	if !ok {
		t.Fatalf("root is %T", document.Root)
	}
	rows := viewport.Columns[0].Rows
	if len(rows) != 2 || rows[0].Height != 600 || rows[1].Height != 400 ||
		rows[1].RowID == nil || *rows[1].RowID != "split_dddddddddddddddddddddddddddddddd" {
		t.Fatalf("rows lost: %+v", rows)
	}
	if viewport.Columns[1].Rows != nil {
		t.Fatalf("a one-row column has no rows: %+v", viewport.Columns[1].Rows)
	}
	encoded, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"rows":[{"row_id":"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","height":600}`) {
		t.Fatalf("rows not encoded: %s", encoded)
	}
	// Row 1 may omit its id in a document sent to workspace.layout.apply.
	first := LayoutRow{Height: 500}
	if encoded, _ := json.Marshal(first); string(encoded) != `{"height":500}` {
		t.Fatalf("row 1 without an id: %s", encoded)
	}
}

func TestLayoutDocumentRowsRefuseBadRows(t *testing.T) {
	for _, bad := range []string{
		`[{"row_id":"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","height":600,"width":1},{"row_id":"split_dddddddddddddddddddddddddddddddd","height":400}]`,
		`[{"row_id":"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","height":50},{"row_id":"split_dddddddddddddddddddddddddddddddd","height":400}]`,
		`[{"row_id":"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},{"row_id":"split_dddddddddddddddddddddddddddddddd","height":400}]`,
	} {
		document := strings.Replace(layoutRowsDocument,
			`[{"row_id":"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","height":600},{"row_id":"split_dddddddddddddddddddddddddddddddd","height":400}]`, bad, 1)
		var decoded LayoutDocument
		if err := json.Unmarshal([]byte(document), &decoded); err == nil {
			t.Fatalf("decoded bad rows %s", bad)
		}
	}
}
