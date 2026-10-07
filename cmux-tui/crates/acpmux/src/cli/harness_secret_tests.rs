use super::*;
use std::cell::RefCell;

const SECRET: &str = "s3cr\"et\\x yz";

fn temp(name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-secret-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("harnesses")).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

/// A config whose user folder holds `acme.toml` with `text`.
fn config_with(name: &str, text: &str) -> (Config, PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp(name);
    let path = dir.join("harnesses").join("acme.toml");
    std::fs::write(&path, text).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let sources = crate::config::ProfileSources {
        managed: vec![],
        user_dir: Some(dir.join("harnesses")),
        cmux_json: None,
    };
    (Config::load_from_with(&dir.join("config.json"), &sources).unwrap(), path)
}

const BASE: &str = "schema = 1\nid = \"acme\"\ncommand = \"/bin/echo\"\n";

fn env_of(path: &Path) -> std::collections::BTreeMap<String, String> {
    let text = std::fs::read_to_string(path).unwrap();
    let (_, profile, _, _) =
        profiles::parse_profile_toml(&text, path, Some("acme"), ProfileSource::UserFile).unwrap();
    profile.env
}

const WANT: &str = "${keychain:cmux-harness/acme/ACME_API_KEY}";

#[test]
fn the_value_never_goes_into_a_command_line() {
    for os in ["macos", "linux"] {
        let cmd = store_command(os, "acme", "ACME_API_KEY", SECRET).unwrap();
        assert!(cmd.argv.iter().all(|a| !a.contains("s3cr")), "{os}: {:?}", cmd.argv);
        assert!(cmd.stdin.contains("s3cr"), "{os}");
    }
    let mac = store_command("macos", "acme", "ACME_API_KEY", SECRET).unwrap();
    assert_eq!(mac.argv, ["/usr/bin/security", "-i"]);
    // `security -i` reads one command line; quotes and backslashes are escaped
    // (checked against /usr/bin/security on a fleet Mac: it stores s3cr"et\x yz).
    assert_eq!(
        mac.stdin,
        "add-generic-password -U -s cmux-harness -a \"acme/ACME_API_KEY\" -l \"cmux harness acme ACME_API_KEY\" -w \"s3cr\\\"et\\\\x yz\"\n"
    );
    let linux = store_command("linux", "acme", "ACME_API_KEY", SECRET).unwrap();
    assert_eq!(
        linux.argv,
        [
            "secret-tool",
            "store",
            "--label",
            "cmux harness acme ACME_API_KEY",
            "service",
            "cmux-harness",
            "account",
            "acme/ACME_API_KEY"
        ]
    );
    assert_eq!(linux.stdin, SECRET);
}

#[test]
fn a_value_with_a_line_break_or_nothing_is_refused() {
    assert!(store_command("macos", "acme", "K", "a\nadd-generic-password -s evil").is_err());
    assert!(store_command("linux", "acme", "K", "").is_err());
    assert!(store_command("linux", "acme", "K", "a\0b").is_err());
}

#[test]
fn secret_set_stores_then_adds_the_reference_under_env() {
    let (cfg, path) = config_with("add", &format!("{BASE}\n[env]\nACME_REGION = \"eu\"\n"));
    let stored = RefCell::new(Vec::new());
    let change = secret_set("acme", "ACME_API_KEY", SECRET, &cfg, &|cmd| {
        stored.borrow_mut().push(cmd.stdin.clone());
        Ok(())
    })
    .unwrap();
    assert_eq!(change, FileChange::Written(path.clone()));
    assert_eq!(stored.borrow().len(), 1);
    let env = env_of(&path);
    assert_eq!(env["ACME_API_KEY"], WANT);
    assert_eq!(env["ACME_REGION"], "eu");
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(!text.contains("s3cr"), "{text}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o077, 0);
    // Again: the file already refers to it.
    let again = secret_set("acme", "ACME_API_KEY", SECRET, &cfg, &|_| Ok(())).unwrap();
    assert_eq!(again, FileChange::Unchanged(path));
}

#[test]
fn a_literal_value_is_replaced_by_the_reference() {
    let (cfg, path) = config_with(
        "literal",
        &format!("{BASE}\n[env]\nACME_API_KEY = \"plain-secret\"\n\n[defaults]\nmodel = \"m\"\n"),
    );
    secret_set("acme", "ACME_API_KEY", SECRET, &cfg, &|_| Ok(())).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(!text.contains("plain-secret"), "{text}");
    assert_eq!(env_of(&path)["ACME_API_KEY"], WANT);
}

#[test]
fn a_file_without_env_gets_an_env_table() {
    let (cfg, path) = config_with("noenv", &format!("{BASE}\n[defaults]\nmodel = \"m\"\n"));
    secret_set("acme", "ACME_API_KEY", SECRET, &cfg, &|_| Ok(())).unwrap();
    assert_eq!(env_of(&path)["ACME_API_KEY"], WANT);
}

#[test]
fn an_unsafe_edit_is_left_to_the_user_and_the_file_is_kept() {
    let original = format!("{BASE}env = {{ ACME_REGION = \"eu\" }}\n");
    let (cfg, path) = config_with("inline", &original);
    let change = secret_set("acme", "ACME_API_KEY", SECRET, &cfg, &|_| Ok(())).unwrap();
    assert!(matches!(change, FileChange::Manual { .. }), "{change:?}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
}

#[test]
fn a_failed_store_writes_nothing_and_bad_names_are_refused() {
    let original = format!("{BASE}\n[env]\n");
    let (cfg, path) = config_with("fail", &original);
    let err = secret_set("acme", "ACME_API_KEY", SECRET, &cfg, &|_| bail!("locked"));
    assert!(err.is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    assert!(secret_set("Acme!", "K", SECRET, &cfg, &|_| Ok(())).is_err());
    assert!(secret_set("acme", "1BAD-KEY", SECRET, &cfg, &|_| Ok(())).is_err());
    let other = secret_set("nope", "K", SECRET, &cfg, &|_| Ok(())).unwrap();
    assert!(matches!(other, FileChange::Manual { path: None, .. }), "{other:?}");
}

#[test]
fn a_piped_value_is_read_into_one_buffer_sized_before_the_read() {
    let mut input: &[u8] = b"s3cret-value\r\n";
    let value = read_secret_from(&mut input).unwrap();
    assert_eq!(value.as_str(), "s3cret-value");
    // Sized for the largest value before the read: no reallocation left a
    // copy of the secret in freed memory that the zeroing cannot reach.
    assert!(value.capacity() > MAX_SECRET_BYTES, "capacity {}", value.capacity());
    let mut long: &[u8] = &[b'a'; MAX_SECRET_BYTES + 1];
    assert!(read_secret_from(&mut long).is_err());
    let mut bad: &[u8] = &[0xff, 0xfe];
    assert!(read_secret_from(&mut bad).is_err());
}
