//! The patch file-header parser `fileContents` uses to decide which paths a
//! session may read (server/file_contents.rs `patch_names_all`: `diff --git`
//! name splitting, C-quoted names, `---`/`+++`, rename and copy lines).
//!
//! Input: the first line is the wanted paths, NUL-separated; the rest is the
//! patch. Nothing wanted is always named, and a patch that names a set names
//! each of its members.
#![no_main]

use cmux_diff_sidecar::server::fuzz_entry;
use libfuzzer_sys::fuzz_target;

/// The most wanted paths checked one by one, so one input stays linear.
const MAX_SINGLE_CHECKS: usize = 8;

fuzz_target!(|data: &[u8]| {
    let (head, patch) = match data.iter().position(|&byte| byte == b'\n') {
        Some(newline) => (&data[..newline], &data[newline + 1..]),
        None => (&data[..0], data),
    };
    let wanted: Vec<String> = head
        .split(|&byte| byte == 0)
        .filter(|name| !name.is_empty())
        .map(|name| String::from_utf8_lossy(name).into_owned())
        .collect();
    assert!(fuzz_entry::patch_names_all(patch, &[]));
    if fuzz_entry::patch_names_all(patch, &wanted) {
        for name in wanted.iter().take(MAX_SINGLE_CHECKS) {
            assert!(
                fuzz_entry::patch_names_all(patch, std::slice::from_ref(name)),
                "the patch names {name:?} with the others but not alone"
            );
        }
    }
});
