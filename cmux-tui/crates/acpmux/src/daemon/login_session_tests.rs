use super::*;

#[test]
fn the_job_loads_only_in_the_aqua_session_and_escapes_its_values() {
    let p = job_plist(
        "com.cmux.acpmux.daemon.x",
        &["/Apps/a&b/acpmux".into(), "daemon".into(), "run".into()],
        &[("ACPMUX_HOME".into(), "/h/<x>".into())],
        Path::new("/h/daemon.log"),
    );
    assert!(p.contains("<key>LimitLoadToSessionType</key><string>Aqua</string>"));
    assert!(p.contains(
        "<string>/Apps/a&amp;b/acpmux</string><string>daemon</string><string>run</string>"
    ));
    assert!(p.contains("<key>ACPMUX_HOME</key><string>/h/&lt;x&gt;</string>"));
    assert!(p.contains("<key>KeepAlive</key><false/>"));
}
