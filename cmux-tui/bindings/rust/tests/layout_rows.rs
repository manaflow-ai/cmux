//! rows-v1: layout documents carry a column's rows, both ways.
#![cfg(unix)]

mod common;

use cmux::{LayoutNode, LayoutOptions, ScreenId, WorkspaceId};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

const SCREEN: &str = "screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const WORKSPACE: &str = "ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const CHAIN: &str = "split_dddddddddddddddddddddddddddddddd";

fn document(rows: Value) -> Value {
    json!({
        "version": 1, "screen_id": SCREEN,
        "active_pane_id": "pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "zoomed_pane_id": null,
        "root": {"kind": "viewport", "base_width": 0.5, "columns": [
            {"column_id": "split_cccccccccccccccccccccccccccccccc", "width": 0.5,
             "root": {"kind": "split", "split_id": CHAIN, "direction": "vertical", "ratio": 0.6,
                "first": {"kind": "leaf", "pane_id": "pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "tab_ids": []},
                "second": {"kind": "leaf", "pane_id": "pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "tab_ids": []}},
             "rows": rows},
            {"column_id": "split_ffffffffffffffffffffffffffffffff", "width": 0.5,
             "root": {"kind": "leaf", "pane_id": "pane_cccccccccccccccccccccccccccccccc", "tab_ids": []}},
        ]},
    })
}

fn rows() -> Value {
    json!([{"row_id": "split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "height": 600},
           {"row_id": CHAIN, "height": 400}])
}

#[test]
fn layout_documents_decode_a_columns_rows_and_send_them_back() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let capture = seen.clone();
    let peer = common::mock(move |stream, reader| {
        let export = common::request(reader, "screen.layout.export");
        common::read_ok(stream, &export, document(rows()));
        let apply = common::request(reader, "workspace.layout.apply");
        common::respond(
            stream,
            &apply,
            json!({"ok": false, "error": {
            "code": "operation.failed", "message": "recorded", "retryable": false, "details": {}}}),
        );
        capture.lock().unwrap().push(apply);
    });
    let client = peer.client();
    let session = peer.session(&client);
    let workspace = session.workspace(WorkspaceId::parse(WORKSPACE).unwrap());
    let layout = workspace.screen(ScreenId::parse(SCREEN).unwrap()).export_layout().unwrap();
    let LayoutNode::Viewport(viewport) = &layout.root else { panic!("{layout:?}") };
    let column_rows = viewport.columns[0].rows.clone().expect("rows");
    assert_eq!(column_rows.len(), 2);
    assert_eq!((column_rows[0].height, column_rows[1].height), (600, 400));
    assert_eq!(column_rows[1].row_id.as_ref().unwrap().as_str(), CHAIN);
    assert!(viewport.columns[1].rows.is_none(), "a one-row column has no rows");
    assert!(workspace.apply_layout(LayoutOptions { document: layout }).is_err());
    peer.finish();
    let apply = seen.lock().unwrap()[0].clone();
    assert_eq!(apply["params"]["layout"]["root"]["columns"][0]["rows"], rows());
    assert!(apply["params"]["layout"]["root"]["columns"][1].get("rows").is_none(), "{apply}");
}

#[test]
fn layout_rows_keep_row_one_without_an_id_and_refuse_bad_rows() {
    let first: cmux::LayoutDocument = serde_json::from_value(document(
        json!([{"height": 500}, {"row_id": CHAIN, "height": 400}]),
    ))
    .unwrap();
    let LayoutNode::Viewport(viewport) = &first.root else { panic!() };
    let row = &viewport.columns[0].rows.as_ref().unwrap()[0];
    assert!(row.row_id.is_none() && row.height == 500);
    assert_eq!(serde_json::to_value(row).unwrap(), json!({"height": 500}));
    for bad in [
        json!([{"row_id": CHAIN, "height": 600, "width": 1}]),
        json!([{"row_id": CHAIN, "height": 50}]),
        json!([{"row_id": CHAIN}]),
        json!("rows"),
    ] {
        assert!(
            serde_json::from_value::<cmux::LayoutDocument>(document(bad.clone())).is_err(),
            "{bad}"
        );
    }
}
