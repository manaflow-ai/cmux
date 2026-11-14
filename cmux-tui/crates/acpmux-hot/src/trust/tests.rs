use super::check;
use std::os::unix::fs::PermissionsExt as _;

fn checkout() -> tempdir::Dir {
    tempdir::Dir::new()
}

/// A private temp folder made a "checkout" by an empty `.git` folder.
mod tempdir {
    pub struct Dir(pub std::path::PathBuf);
    impl Dir {
        pub fn new() -> Self {
            use std::os::unix::fs::PermissionsExt as _;
            let base = std::env::temp_dir().canonicalize().unwrap();
            let n = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let dir = base.join(format!("acpmux-hot-trust-{}-{n}", std::process::id()));
            std::fs::create_dir_all(dir.join(".git")).unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
            Dir(dir)
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

#[test]
fn a_private_file_in_a_checkout_loads() {
    let dir = checkout();
    let file = dir.0.join("m.wasm");
    std::fs::write(&file, b"x").unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(check(&file).unwrap(), file);
}

#[test]
fn a_relative_path_a_shared_file_or_a_file_outside_a_checkout_is_refused() {
    assert!(check(std::path::Path::new("m.wasm")).is_err());
    let dir = checkout();
    let file = dir.0.join("m.wasm");
    std::fs::write(&file, b"x").unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o666)).unwrap();
    assert!(check(&file).unwrap_err().contains("writable by group or others"));
    std::fs::remove_dir(dir.0.join(".git")).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    // Above the temp folder, `/tmp`-like folders are writable by others or not a checkout.
    assert!(check(&file).is_err());
}
