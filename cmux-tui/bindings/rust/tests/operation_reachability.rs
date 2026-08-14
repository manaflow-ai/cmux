#[test]
fn every_high_level_operation_constant_has_a_facade_call_site() {
    let operations = include_str!("../src/resource/ops.rs");
    let call_sites = [
        include_str!("../src/resource/handles.rs"),
        include_str!("../src/resource/client.rs"),
        include_str!("../src/resource/stream.rs"),
    ]
    .join("\n");

    let names = operations
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            let rest = line.strip_prefix("pub(crate) const ")?;
            Some(rest.split(':').next().unwrap())
        })
        .collect::<Vec<_>>();
    assert_eq!(names.len(), 114, "update this count only with the accepted inventory");
    for name in names {
        assert!(
            call_sites.contains(&format!("ops::{name}")),
            "{name} has no high-level facade call site"
        );
    }
}
