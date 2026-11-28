use cmux_auto_session::holder::Stop;
use serde_json::{Value, json};

use super::*;
use crate::auto_session::record::Mode;

const ME: &str = "device:laptop-1";

fn chat(state: State) -> Tracked {
    Tracked::new(Chat { state, ..Chat::new(Side::Laptop, 0) })
}

/// The chat's record on the laptop [`ME`].
fn read(tracked: &Tracked, old: Option<AutoRecord>) -> Option<AutoRecord> {
    record_of(tracked, &Holder::device("laptop-1"), old)
}

/// The store's view of a chat `holder` has, with the fields of `more`.
fn view(holder: &str, more: Value) -> SessionView {
    let mut view = json!({
        "id": "c", "auto": true, "holder": holder, "epoch": 2, "state": "cloud", "version": 1,
    });
    for (name, value) in more.as_object().into_iter().flatten() {
        view[name.as_str()] = value.clone();
    }
    serde_json::from_value(view).unwrap()
}

#[test]
fn this_machine_only_lasts_while_the_chat_is_on_its_way_here_or_here() {
    let wanted = || Some(AutoRecord { local_wanted: true, ..AutoRecord::on() });
    let stays = |tracked: &Tracked| read(tracked, wanted()).unwrap().local_wanted;
    // No view yet (a daemon that just started): as the record has it.
    let mut away = chat(State::Standby { epoch: 2 });
    assert!(stays(&away));
    // The Cloud machine has the chat and the store tells the wish to bring it here.
    away.view = Some(view("vm:vm_1", json!({"move": {"to": "local", "device": ME}})));
    assert!(stays(&away));
    away.view = Some(view("vm:vm_1", json!({"move": {"to": "local"}})));
    assert!(stays(&away));
    // The store gave a parked chat to this laptop at once: it is taking it.
    away.view = Some(view(ME, json!({})));
    assert!(stays(&away));
    // The wish names another laptop, or it ran out or was refused: the chat is not coming.
    away.view = Some(view("vm:vm_1", json!({"move": {"to": "local", "device": "device:b"}})));
    assert!(!stays(&away));
    away.view = Some(view("vm:vm_1", json!({})));
    assert!(!stays(&away));
    let auto = read(&away, wanted()).unwrap();
    assert_eq!((auto.auto, auto.mode()), (true, Mode::Auto));

    // Home, waiting for its own copy before Auto goes off.
    let mut home = chat(State::Holding { epoch: 3 });
    home.view = Some(view(ME, json!({})));
    assert!(stays(&home));
    // The person picked Cloud for it from another device meanwhile.
    home.view = Some(view(ME, json!({"keepInCloud": true, "move": {"to": "cloud"}})));
    let cloud = read(&home, wanted()).unwrap();
    assert_eq!((cloud.local_wanted, cloud.mode()), (false, Mode::Cloud));
}

#[test]
fn a_chat_being_given_reads_where_it_still_is_and_is_frozen() {
    use cmux_auto_session::holder::GiveStep;
    let step = GiveStep::Copying;
    let giving = chat(State::Giving { epoch: 3, step, to: MoveTo::Cloud });
    assert!(frozen(&giving.chat));
    let record = read(&giving, None).unwrap();
    assert!(record.here);
    assert_eq!(record.state, wire::State::Local);
    let returning = chat(State::Returning { epoch: 4, step, to: MoveTo::Local });
    assert!(frozen(&returning.chat));
    let record = read(&returning, None).unwrap();
    assert!(record.here);
    assert_eq!(record.state, wire::State::Cloud);
}

#[test]
fn a_chat_stopped_here_reads_as_here_and_frozen() {
    let stopped = chat(State::Stopped { epoch: 3, why: Stop::Offline });
    assert!(frozen(&stopped.chat));
    let record = read(&stopped, None).unwrap();
    assert!(record.auto && record.here);
    assert_eq!(record.epoch, 3);
    assert_eq!(record.state, wire::State::Local);
    assert_eq!(record.blocked, Some(Blocked::Offline));
}

#[test]
fn a_chat_with_auto_off_keeps_a_record_only_for_its_leftover() {
    let off = chat(State::Off);
    assert!(!frozen(&off.chat));
    assert_eq!(read(&off, None), None);
    assert_eq!(read(&off, Some(AutoRecord::on())), None);
    let mut kept = AutoRecord::on();
    kept.leftover = Some(crate::auto_session::record::Leftover {
        files: vec!["a".into()],
        at: 1,
        path: "/x/p".into(),
        top: "/x".into(),
    });
    let record = read(&off, Some(kept)).unwrap();
    assert!(!record.auto);
    assert!(record.leftover.is_some());
}

#[test]
fn a_standby_chat_reads_where_the_store_says_it_is() {
    let standby = chat(State::Standby { epoch: 2 });
    assert!(frozen(&standby.chat));
    let record = read(&standby, None).unwrap();
    assert!(!record.here);
    assert_eq!(record.state, wire::State::Cloud);
    let home = chat(State::ComingHome { epoch: 4, failed: false });
    assert_eq!(read(&home, None).unwrap().state, wire::State::ComingBack);
}
