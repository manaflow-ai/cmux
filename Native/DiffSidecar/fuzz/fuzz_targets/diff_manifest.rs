//! The token-bound manifest (manifest.rs: the JSON the app writes, its entry
//! validation and the resource paths a request resolves through). A
//! validated entry resolves back to itself from its resource URL path, and a
//! resource path that resolves never escapes with `..`, `.` or `//`.
#![no_main]

use cmux_diff_sidecar::manifest::{Manifest, split_resource_path, valid_request_path, valid_token};
use libfuzzer_sys::fuzz_target;

fn check_resource_path(path: &str) {
    if let Some((token, request_path)) = split_resource_path(path) {
        assert!(valid_token(token));
        assert!(valid_request_path(&request_path));
        assert!(
            request_path
                .split('/')
                .skip(1)
                .all(|component| !matches!(component, "" | "." | "..")),
            "{request_path:?} escapes"
        );
    }
}

fuzz_target!(|data: &[u8]| {
    check_resource_path(&String::from_utf8_lossy(data));
    let Ok(manifest) = serde_json::from_slice::<Manifest>(data) else {
        return;
    };
    let Ok(files) = manifest.files_by_path() else {
        return;
    };
    for (request_path, file) in &files {
        assert_eq!(request_path, &file.request_path);
        assert!(file.validate().is_ok());
        if valid_token(&manifest.token) {
            let resource_path = format!("/{}{request_path}", manifest.token);
            assert_eq!(
                split_resource_path(&resource_path),
                Some((manifest.token.as_str(), request_path.clone())),
                "a manifest entry resolves to itself"
            );
        }
    }
});
