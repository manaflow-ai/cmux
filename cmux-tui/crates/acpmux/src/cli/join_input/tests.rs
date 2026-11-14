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
