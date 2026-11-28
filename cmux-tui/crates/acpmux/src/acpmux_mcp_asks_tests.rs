use super::*;

fn names(all: &Value) -> Vec<String> {
    all.as_array().unwrap().iter().filter_map(|t| t["name"].as_str().map(str::to_owned)).collect()
}

#[test]
fn the_ask_tools_are_listed_only_where_the_ledger_captured() {
    let off = names(&super::super::with_asks(super::super::tools(), false));
    let on = names(&super::super::with_asks(super::super::tools(), true));
    for tool in TOOLS {
        assert!(!off.iter().any(|n| n == tool), "{tool} listed with no ledger");
        assert!(on.iter().any(|n| n == tool), "{tool} missing");
    }
    for tool in tools() {
        let name = tool["name"].as_str().unwrap();
        assert!(name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'), "{name}");
    }
}

#[test]
fn each_tool_maps_to_its_daemon_method() {
    assert_eq!(request("asks_search", &json!({"q": "x"})).unwrap().0, method::MUX_ASKS_SEARCH);
    assert_eq!(request("asks_get", &json!({"id": "a"})).unwrap().0, method::MUX_ASKS_GET);
    let (m, params) = request("asks_link", &json!({"id": "a", "kind": "picked"})).unwrap();
    assert_eq!(m, method::MUX_ASKS_LINK);
    assert_eq!(params["kind"], "picked");
    assert!(request("asks_get", &json!("a")).is_err());
}
