//! A panic on any Chief thread lands in `$MUX_HOME/optchat/panics.jsonl` as
//! one `cmux-panic-log` line labeled `optchat-chief` with its verb; a home
//! with no `optchat/` folder yet gets no log.

use optchat_chief::panic_log;
use optchat_chief::paths::Paths;

#[test]
fn a_thread_panic_writes_one_line_in_the_optchat_folder() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let early = dir.path().join("fresh");
    Paths::new(&home).create().unwrap();
    let path = panic_log::log_path(&home);
    assert_eq!(path, home.join("optchat").join("panics.jsonl"));

    // A fresh home first: no optchat/ folder, so its panic is not logged.
    // Both installs are the same as `main`'s.
    let early_log = panic_log::log_path(&early);
    cmux_panic_log::install(early_log, panic_log::fields("mcp"), |_| false);
    let joined = std::thread::Builder::new()
        .name("chief-early".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("before the first host start"))
        .unwrap()
        .join();
    assert!(joined.is_err());
    assert!(!panic_log::log_path(&early).exists());

    cmux_panic_log::install(path.clone(), panic_log::fields("host"), |_| false);
    let joined = std::thread::Builder::new()
        .name("chief-worker".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("chief test panic"))
        .unwrap()
        .join();
    assert!(joined.is_err());

    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(lines.len(), 1, "{text}");
    assert_eq!(lines[0]["process"], "optchat-chief");
    assert_eq!(lines[0]["verb"], "host");
    assert_eq!(lines[0]["message"], "chief test panic");
    assert_eq!(lines[0]["thread"], "chief-worker");
    assert_eq!(lines[0]["test"], false);
}
