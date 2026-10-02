// Intentionally emit no `rerun-if-*` directives. Cargo then fingerprints this
// root package with its Git-aware source walker, which prunes target/ and still
// notices newly-created workspace-root files.
fn main() {}
