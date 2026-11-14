use super::*;
use serde_json::json;
use std::cell::RefCell;

#[tokio::test]
async fn a_peer_row_without_tools_reads_them_from_its_info() {
    let mut rows = vec![
        json!({"sessionId": "own", "tools": [{"id": "mcp:own"}], "toolsMutable": true}),
        json!({"sessionId": "a", "peer": "hb", "qualifiedSessionId": "hb/a"}),
        json!({"sessionId": "b", "peer": "hb", "qualifiedSessionId": "hb/b",
                "tools": [{"id": "mcp:kept"}], "toolsMutable": false}),
        json!({"sessionId": "c", "peer": "gone", "qualifiedSessionId": "gone/c"}),
    ];
    let asked = RefCell::new(Vec::new());
    let failed = fill(&mut rows, |key| {
        asked.borrow_mut().push(key.clone());
        async move {
            match key.as_str() {
                "hb/a" => Ok(json!({"sessionId": "a", "tools": [{"id": "mcp:a"}],
                        "toolsMutable": true, "title": "not copied"})),
                "hb/b" => Ok(json!({"tools": [{"id": "mcp:now"}], "toolsMutable": true})),
                _ => Err(anyhow::anyhow!("peer gone is not connected")),
            }
        }
    })
    .await;
    let mut asked = asked.into_inner();
    asked.sort();
    assert_eq!(asked, ["gone/c", "hb/a", "hb/b"], "every peer row is read, own rows are not");
    assert_eq!(failed, 1);
    assert_eq!(rows[0]["tools"], json!([{"id": "mcp:own"}]));
    assert_eq!(rows[1]["tools"], json!([{"id": "mcp:a"}]));
    assert_eq!(rows[1]["toolsMutable"], true);
    assert!(rows[1].get("title").is_none(), "only the inventory is copied: {}", rows[1]);
    // A peer row's tools may be kept from an earlier attachment or list: read them again.
    assert_eq!(rows[2]["tools"], json!([{"id": "mcp:now"}]), "a cached inventory is refreshed");
    assert_eq!(rows[2]["toolsMutable"], true);
    assert!(rows[3].get("tools").is_none(), "a row that could not be read stays as listed");
    let mut kept = vec![json!({"sessionId": "b", "peer": "hb", "tools": [{"id": "mcp:kept"}]})];
    assert_eq!(fill(&mut kept, |_| async { Err(anyhow::anyhow!("gone")) }).await, 1);
    assert_eq!(kept[0]["tools"], json!([{"id": "mcp:kept"}]), "kept when it cannot be read");
}

#[tokio::test]
async fn a_row_with_no_qualified_id_is_read_by_peer_and_id() {
    let mut rows = vec![json!({"sessionId": "a", "peer": "hb"})];
    let failed = fill(&mut rows, |key| async move {
        assert_eq!(key, "hb/a");
        Ok(json!({"tools": [], "toolsMutable": false}))
    })
    .await;
    assert_eq!(failed, 0);
    assert_eq!(rows[0]["tools"], json!([]));
}
