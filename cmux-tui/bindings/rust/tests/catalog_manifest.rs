use serde_json::Value;
use sha2::{Digest, Sha256};

#[test]
fn capability_manifest_exactly_matches_the_canonical_catalog() {
    let catalog: Value =
        serde_json::from_str(include_str!("../../../spec/resource-operations-v2.json")).unwrap();
    let manifest: Value = serde_json::from_str(include_str!("../.cmux-resource-api.json")).unwrap();

    assert_eq!(manifest["protocol"], catalog["protocol"]);
    let canonical_catalog = serde_json::to_vec(&catalog).unwrap();
    assert_eq!(manifest["catalog_sha256"], format!("{:x}", Sha256::digest(canonical_catalog)));
    let expected = catalog["operations"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(name, operation)| (name.clone(), serde_json::json!({"class": operation["class"]})))
        .collect::<serde_json::Map<_, _>>();
    assert_eq!(manifest["operations"], Value::Object(expected));
}
