use serde_json::Value;

#[test]
fn capability_manifest_exactly_matches_the_canonical_catalog() {
    let catalog: Value =
        serde_json::from_str(include_str!("../../../spec/resource-operations-v1.json")).unwrap();
    let manifest: Value = serde_json::from_str(include_str!("../.cmux-resource-api.json")).unwrap();

    assert_eq!(manifest["protocol"], catalog["protocol"]);
    assert_eq!(
        manifest["catalog_sha256"],
        "dfcf3f938a6f2ca6175cb6d6ecb32eb9bc2de25c7e448aee58aa0b67d430d841"
    );
    let expected = catalog["operations"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(name, operation)| (name.clone(), serde_json::json!({"class": operation["class"]})))
        .collect::<serde_json::Map<_, _>>();
    assert_eq!(manifest["operations"], Value::Object(expected));
}
