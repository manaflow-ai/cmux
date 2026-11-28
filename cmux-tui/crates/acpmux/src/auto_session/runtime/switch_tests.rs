use super::*;

#[test]
fn a_prompt_id_the_store_takes_is_the_message_id() {
    assert_eq!(message_id(Some("p-1_a.b:c")), "p-1_a.b:c");
    let minted = message_id(Some("has space"));
    assert_ne!(minted, "has space");
    assert!(minted.len() <= MESSAGE_ID_MAX);
    assert_ne!(message_id(None), message_id(None));
}

#[test]
fn switching_on_again_starts_from_nothing_but_keeps_the_leftover() {
    let mut old = AutoRecord::on();
    old.auto = false;
    old.epoch = 9;
    old.snapshot = 4;
    old.anchor = Some("tree".into());
    old.leftover = Some(crate::auto_session::record::Leftover {
        files: vec!["a".into()],
        at: 1,
        path: "/x/p".into(),
        top: "/x".into(),
    });
    let record = fresh_record(Some(old), Some(true));
    assert!(record.auto && record.here && record.keep_in_cloud);
    assert_eq!((record.epoch, record.snapshot, record.anchor.clone()), (0, 0, None));
    assert!(record.leftover.is_some());
}
