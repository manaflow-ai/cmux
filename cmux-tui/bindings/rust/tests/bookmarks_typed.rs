//! The typed `bookmarks-v1` raw layer (spec/commands.md "list-bookmarks"
//! and after): typed results for the six commands and typed, recursive
//! `import-bookmarks` nodes. Results decode forward-compatibly: `kind` is a
//! string, and fields this SDK does not know stay in `additional`.

mod common;

use cmux::raw::{
    BookmarkImportNode, CreateBookmarkRequest, ImportBookmarksRequest, ListBookmarksRequest,
    MoveBookmarkRequest, Optional,
};
use common::{command, mock, reply};
use serde_json::json;

const FOLDER: &str = "bm_0123456789abcdef0123456789abcdef";
const PAGE: &str = "bm_fedcba9876543210fedcba9876543210";

fn folder() -> serde_json::Value {
    json!({"id": FOLDER, "browser_profile_id": "default", "parent": "bar", "kind": "folder",
           "index": 0, "title": "Work", "source_key": "import:1", "created_ms": 1000})
}

fn page() -> serde_json::Value {
    json!({"id": PAGE, "browser_profile_id": "default", "parent": FOLDER, "kind": "url",
           "index": 0, "title": "Docs", "url": "https://cmux.com/docs", "created_ms": 2000,
           "last_used_ms": 3000})
}

#[test]
fn bookmark_results_are_typed_and_keep_unknown_fields() {
    let mock = mock(|stream, reader| {
        let list = command(reader, "list-bookmarks");
        assert_eq!(list["browser_profile_id"], "default");
        let mut future = page();
        future["kind"] = json!("separator");
        future["tint"] = json!("red");
        let data = json!({"bookmarks_revision": 7, "bookmarks": [folder(), page(), future]});
        reply(stream, &list, json!({"ok": true, "data": data}));

        let create = command(reader, "create-bookmark");
        assert_eq!(
            (&create["parent"], &create["kind"], &create["origin"], &create["mutation_id"]),
            (&json!(FOLDER), &json!("url"), &json!("cmux2-gpui"), &json!("m-1"))
        );
        let data = json!({"bookmark": page(), "changed": true, "replayed": false});
        reply(stream, &create, json!({"ok": true, "data": data}));

        let moved = command(reader, "move-bookmark");
        assert_eq!((&moved["bookmark"], &moved["index"]), (&json!(PAGE), &json!(1)));
        let data = json!({"bookmark": page(), "changed": false, "replayed": true});
        reply(stream, &moved, json!({"ok": true, "data": data}));

        let delete = command(reader, "delete-bookmark");
        let data = json!({"deleted": [FOLDER, PAGE], "replayed": false});
        reply(stream, &delete, json!({"ok": true, "data": data}));
    });
    let mut raw = mock.raw();
    let listed = raw.list_bookmarks(ListBookmarksRequest { browser_profile_id: "default".into() });
    let listed = listed.unwrap();
    assert_eq!((listed.bookmarks_revision, listed.bookmarks.len()), (7, 3));
    assert_eq!(listed.bookmarks[0].source_key.as_deref(), Some("import:1"));
    assert_eq!(listed.bookmarks[1].url.as_deref(), Some("https://cmux.com/docs"));
    assert_eq!(listed.bookmarks[1].last_used_ms, Some(3000));
    assert_eq!(listed.bookmarks[2].kind, "separator");
    assert_eq!(listed.bookmarks[2].additional["tint"], "red");

    let created = raw
        .create_bookmark(CreateBookmarkRequest {
            browser_profile_id: "default".into(),
            parent: FOLDER.into(),
            kind: "url".into(),
            title: "Docs".into(),
            index: Optional::Missing,
            url: Optional::Value("https://cmux.com/docs".into()),
            favicon_key: Optional::Missing,
            source_key: Optional::Missing,
            created_ms: Optional::Missing,
            bookmark: Optional::Missing,
            origin: Optional::Value("cmux2-gpui".into()),
            mutation_id: Optional::Value("m-1".into()),
        })
        .unwrap();
    assert_eq!(
        (created.bookmark.id.as_str(), created.changed, created.replayed),
        (PAGE, true, false)
    );
    let moved = raw
        .move_bookmark(MoveBookmarkRequest {
            bookmark: PAGE.into(),
            parent: FOLDER.into(),
            index: 1,
            origin: Optional::Missing,
            mutation_id: Optional::Missing,
        })
        .unwrap();
    assert!(moved.replayed && !moved.changed);
    let deleted = raw
        .delete_bookmark(cmux::raw::DeleteBookmarkRequest {
            bookmark: FOLDER.into(),
            origin: Optional::Missing,
            mutation_id: Optional::Missing,
        })
        .unwrap();
    assert_eq!(deleted.deleted, [FOLDER, PAGE]);
    raw.close();
    mock.finish();
}

#[test]
fn import_nodes_are_typed_and_nest() {
    let mock = mock(|stream, reader| {
        let import = command(reader, "import-bookmarks");
        assert_eq!(
            import["nodes"],
            json!([{"kind": "folder", "title": "Imported", "children": [
                {"kind": "url", "title": "Docs", "url": "https://cmux.com/docs",
                 "created_ms": 5}]}])
        );
        assert_eq!((&import["replace"], &import["source_key"]), (&json!(true), &json!("html:1")));
        let data = json!({"root_ids": [FOLDER], "count": 2, "replayed": false});
        reply(stream, &import, json!({"ok": true, "data": data}));
    });
    let mut raw = mock.raw();
    let page = BookmarkImportNode {
        kind: "url".into(),
        title: "Docs".into(),
        url: Some("https://cmux.com/docs".into()),
        created_ms: Some(5),
        children: None,
    };
    let folder = BookmarkImportNode {
        kind: "folder".into(),
        title: "Imported".into(),
        url: None,
        created_ms: None,
        children: Some(vec![Box::new(page)]),
    };
    let imported = raw
        .import_bookmarks(ImportBookmarksRequest {
            browser_profile_id: "default".into(),
            parent: "other".into(),
            index: Optional::Missing,
            source_key: Optional::Value("html:1".into()),
            replace: Some(true),
            nodes: vec![folder],
            origin: Optional::Missing,
            mutation_id: Optional::Missing,
        })
        .unwrap();
    assert_eq!(
        (imported.root_ids.as_slice(), imported.count),
        ([FOLDER.to_string()].as_slice(), 2)
    );
    raw.close();
    mock.finish();
}
