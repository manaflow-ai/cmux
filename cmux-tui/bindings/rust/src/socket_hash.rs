//! Session-name digests used to derive socket paths.
//!
//! The daemon names a session socket by the SHA-256 of the session name when
//! the plain path does not fit `sun_path`. The `sha2` dependency is optional
//! (cargo feature `socket-path-hash`, on by default) so embedders that pass an
//! explicit socket path, such as Chromium's vendored-crate build, can drop it.
//! Without the feature the SDK refuses to derive a hashed path instead of
//! guessing one that differs from the daemon's.

/// Error text for a session whose socket path needs the digest fallback.
pub(crate) const LONG_PATH_NEEDS_HASH: &str = "session socket path exceeds the Unix socket \
     limit; enable the cmux-sdk feature socket-path-hash or pass an explicit socket path";

/// Lowercase hex SHA-256 of `session`, or `None` without `socket-path-hash`.
#[cfg(feature = "socket-path-hash")]
pub(crate) fn session_digest(session: &str) -> Option<String> {
    use sha2::{Digest as _, Sha256};
    Some(format!("{:x}", Sha256::digest(session.as_bytes())))
}

/// Lowercase hex SHA-256 of `session`, or `None` without `socket-path-hash`.
#[cfg(not(feature = "socket-path-hash"))]
pub(crate) fn session_digest(_session: &str) -> Option<String> {
    None
}

/// Leaf of the path-only socket for an invalid session name. It is never a
/// connection route, so without SHA-256 a stable FNV-1a 64 digest keeps
/// distinct inputs on distinct paths.
pub(crate) fn invalid_session_leaf(session: &str) -> String {
    match session_digest(session) {
        Some(digest) => format!("{digest}.sock"),
        None => format!("invalid-{:016x}.sock", fnv1a64(session.as_bytes())),
    }
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    // Each feature combination uses a different subset.
    #[allow(unused_imports)]
    use crate::client::{
        ClientConfig, CmuxError, current_uid_component, default_socket_path,
        default_socket_path_in_runtime_dir, hashed_socket_legacy_path, try_default_socket_path,
        unix_socket_path_fits,
    };
    #[allow(unused_imports)]
    use std::os::unix::net::UnixListener;
    #[allow(unused_imports)]
    use std::path::{Path, PathBuf};

    #[cfg(feature = "socket-path-hash")]
    #[test]
    fn long_session_socket_path_uses_bindable_digest_fallback() {
        const EXPECTED_DIGEST: &str =
            "e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2";
        let session = format!("legacy-{}", "x".repeat(200));
        let path = try_default_socket_path(&session).unwrap();
        let expected_leaf = format!("{EXPECTED_DIGEST}.sock");

        assert_eq!(path.file_name().and_then(|name| name.to_str()), Some(expected_leaf.as_str()));
        assert!(
            path.parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name.to_string_lossy().starts_with("cmux-tui-hashed-"))
        );
        assert!(unix_socket_path_fits(&path), "unusable socket path: {path:?}");

        let bind_session = format!("rust-sdk-bind-{}-{}", std::process::id(), "x".repeat(200));
        let bind_path = try_default_socket_path(&bind_session).unwrap();
        std::fs::create_dir_all(bind_path.parent().unwrap()).unwrap();
        let _ = std::fs::remove_file(&bind_path);
        let listener = UnixListener::bind(&bind_path)
            .unwrap_or_else(|error| panic!("failed to bind {bind_path:?}: {error}"));
        drop(listener);
        std::fs::remove_file(bind_path).unwrap();
    }

    #[cfg(feature = "socket-path-hash")]
    #[test]
    fn long_session_hash_prefers_runtime_base_and_falls_back_to_tmp() {
        let session = format!("legacy-{}", "x".repeat(200));
        let preferred_runtime = PathBuf::from("/run/user/501/cmux-tui-501");
        let preferred = default_socket_path_in_runtime_dir(&session, preferred_runtime).unwrap();
        assert!(preferred.to_string_lossy().starts_with("/run/user/501/cmux-tui-hashed-"));

        let long_runtime = PathBuf::from("/tmp").join("x".repeat(200)).join("cmux-tui-501");
        let fallback = default_socket_path_in_runtime_dir(&session, long_runtime).unwrap();
        assert!(fallback.to_string_lossy().starts_with("/tmp/cmux-tui-hashed-"));
    }

    #[cfg(feature = "socket-path-hash")]
    #[test]
    fn non_ascii_long_session_uses_utf8_sha256_digest_fallback() {
        const EXPECTED_DIGEST: &str =
            "0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3";
        let session = "名前".repeat(100);
        let path = try_default_socket_path(&session).unwrap();
        let expected_leaf = format!("{EXPECTED_DIGEST}.sock");

        assert_eq!(path.file_name().and_then(|name| name.to_str()), Some(expected_leaf.as_str()));
        assert!(
            path.parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name.to_string_lossy().starts_with("cmux-tui-hashed-"))
        );
    }

    #[test]
    fn fnv_leaf_is_stable_and_input_specific() {
        assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
        assert_ne!(fnv1a64(b"../escape"), fnv1a64(b"nested/escape"));
    }

    #[cfg(not(feature = "socket-path-hash"))]
    #[test]
    fn long_session_path_without_the_hash_feature_is_an_error_not_a_guess() {
        let error = try_default_socket_path(&format!("legacy-{}", "x".repeat(200))).unwrap_err();
        assert!(
            matches!(&error, CmuxError::InvalidArgument(message) if message.contains("socket-path-hash")),
            "{error:?}"
        );
        assert!(try_default_socket_path("main").is_ok());
        assert!(ClientConfig::try_from_env_or_default_session("main").is_ok());
    }

    #[cfg(not(feature = "socket-path-hash"))]
    #[test]
    fn invalid_session_compat_path_stays_isolated_without_the_hash_feature() {
        let escaped = default_socket_path("../escape");
        assert_eq!(escaped, default_socket_path("../escape"));
        assert_ne!(escaped, default_socket_path("nested/escape"));
        assert!(
            escaped
                .parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name.to_string_lossy().starts_with("cmux-tui-invalid-"))
        );
        assert!(!escaped.to_string_lossy().contains("../"));
    }

    #[cfg(not(feature = "socket-path-hash"))]
    #[test]
    fn hashed_legacy_probe_is_disabled_without_the_hash_feature() {
        let path = PathBuf::from("/tmp")
            .join(format!("cmux-tui-hashed-{}", current_uid_component()))
            .join(format!("{}.sock", "a".repeat(64)));
        assert_eq!(hashed_socket_legacy_path(&path), None);
    }
}
