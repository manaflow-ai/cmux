use super::{parse_line, validate_arguments};

#[test]
fn accepts_one_trimmed_line_only() {
    assert_eq!(&*parse_line(b" cmj_abc \n").unwrap(), "cmj_abc");
    assert_eq!(&*parse_line(b"cmxt1.ticket\r\n").unwrap(), "cmxt1.ticket");
    assert_eq!(&*parse_line(b"cmxt1.ticket").unwrap(), "cmxt1.ticket");
    assert!(parse_line(b"cmxt1.ticket\r").is_err());
    assert!(parse_line(b"cmj_abc").is_err());
    assert!(parse_line(b"cmj_abc\nsecond\n").is_err());
    assert!(parse_line(b"\xff\n").is_err());
}
#[test]
fn cloud_token_in_argv_is_refused_with_every_flag_combination() {
    for hub in [false, true] {
        for replace in [false, true] {
            for status in [false, true] {
                let error =
                    validate_arguments(Some("cmj_secret"), hub, replace, status).unwrap_err();
                assert!(!error.to_string().contains("cmj_secret"));
            }
        }
    }
    assert!(validate_arguments(Some("cmxt1.legacy"), false, false, false).is_ok());
    assert!(validate_arguments(Some("cmxt1.legacy"), true, false, false).is_err());
    assert!(validate_arguments(None, true, true, false).is_ok());
}

#[cfg(unix)]
#[test]
fn a_join_refuses_a_symlinked_home_naming_its_target() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("supervised");
    std::fs::create_dir(&target).unwrap();
    let link = dir.path().join("home-link");
    std::os::unix::fs::symlink(&target, &link).unwrap();

    let err = super::refuse_symlinked_home_at(&link).unwrap_err();
    let app = err.downcast_ref::<crate::cli::errors::AppError>().unwrap();
    assert_eq!(app.detail, "join.home_symlink");
    assert!(app.message.contains(&format!("ACPMUX_HOME={}", target.display())), "{}", app.message);

    // A relative link names the target beside the link.
    let relative = dir.path().join("home-link-rel");
    std::os::unix::fs::symlink("supervised", &relative).unwrap();
    let err = super::refuse_symlinked_home_at(&relative).unwrap_err();
    assert!(err.to_string().contains(&format!("ACPMUX_HOME={}", target.display())), "{err}");

    // A real directory, or none yet, joins as before.
    super::refuse_symlinked_home_at(&target).unwrap();
    super::refuse_symlinked_home_at(&dir.path().join("missing")).unwrap();
}
