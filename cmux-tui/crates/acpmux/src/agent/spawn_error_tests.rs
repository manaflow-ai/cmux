use super::*;

#[test]
fn out_of_descriptors_says_it_is_the_daemon_and_what_to_do() {
    let error = spawn_error("start host", std::io::Error::from_raw_os_error(libc::EMFILE));
    let text = format!("{error:#}");
    assert!(text.starts_with("start host: the acpmux daemon is out of open files"), "{text}");
    assert!(text.contains("acpmux daemon shutdown"), "{text}");
    let other = spawn_error("start host", std::io::Error::from_raw_os_error(libc::ENOENT));
    assert!(format!("{other:#}").starts_with("start host: "), "{other:#}");
}

#[tokio::test]
async fn direct_spawn_failure_does_not_expose_harness_argv() {
    const SENTINEL: &str = "argv-secret-must-not-leave-the-daemon";
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/nonexistent/acpmux-test-harness", "--token", SENTINEL]
    }))
    .unwrap();
    let (inbound, _rx) = mpsc::channel(1);
    let tap: Tap = Arc::new(|_, _, _| Some(WriteTicket::done()));
    let (temp, supervisor) = (std::env::temp_dir(), crate::supervised::embedded());
    let error = match ChildAgent::spawn("missing", &profile, &temp, inbound, tap, &supervisor).await
    {
        Ok(_) => panic!("a missing harness started"),
        Err(error) => error,
    };
    assert!(!error.to_string().contains(SENTINEL), "spawn failure exposed harness argv: {error:#}");
}
