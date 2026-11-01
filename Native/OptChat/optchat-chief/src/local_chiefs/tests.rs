use std::path::Path;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::*;

struct FakeDirectory;

impl Directory for FakeDirectory {
    fn chiefs(&self) -> Result<Vec<Value>, String> {
        Ok(vec![
            json!({"id": "agent_mux", "display_name": "Chief", "is_default": true}),
            json!({"id": "agent_01CODEX", "display_name": "Codex Chief"}),
            json!({"id": "agent_01HYBRID", "display_name": "Hybrid Chief"}),
            json!({"id": "agent_01OLD", "display_name": "Old Chief", "archived_at": "2026-10-01T00:00:00Z"}),
        ])
    }

    fn conversation_of(&self, chief: &str) -> Result<Option<String>, String> {
        Ok((chief != "agent_01HYBRID").then(|| format!("conv-{chief}")))
    }
}

/// Records each send and answers with one reply message.
#[derive(Default)]
struct FakeCourier {
    sent: Mutex<Vec<(String, String, String)>>,
}

impl Courier for FakeCourier {
    fn send(&self, conversation: &str, from: &str, message: &str) -> Result<String, String> {
        self.sent
            .lock()
            .unwrap()
            .push((conversation.into(), from.into(), message.into()));
        Ok(format!(
            "{}\n",
            json!({"seq": 9, "author": "agent_01CODEX", "parts": [{"type": "text", "text": "green on main"}]})
        ))
    }
}

type Delivered = Arc<Mutex<Vec<(String, String)>>>;

fn chiefs(me: &str) -> (LocalChiefs, Arc<FakeCourier>, Delivered) {
    let courier = Arc::new(FakeCourier::default());
    let delivered: Delivered = Arc::default();
    let sink = delivered.clone();
    let (id, name) = match me {
        "agent_mux" => ("agent_mux", "Chief"),
        _ => ("agent_01CODEX", "Codex Chief"),
    };
    let local = LocalChiefs::new(
        Box::new(move || {
            Some(Local {
                id: id.into(),
                name: name.into(),
            })
        }),
        Arc::new(FakeDirectory),
        courier.clone(),
        Arc::new(move |from, note| sink.lock().unwrap().push((from, note))),
    )
    .with_spawn(|work| work());
    (local, courier, delivered)
}

#[test]
fn a_local_chief_is_named_by_its_handle_its_name_or_its_id() {
    let (local, _, _) = chiefs("agent_mux");
    for id in [
        "chief:codex-chief",
        "chief:Codex Chief",
        "chief: codex chief ",
        "chief:agent_01CODEX",
    ] {
        assert_eq!(
            local.find(id).unwrap().map(|c| c.id),
            Some("agent_01CODEX".to_owned()),
            "{id}"
        );
    }
    assert_eq!(local.find("chief:old-chief").unwrap(), None, "archived");
    assert_eq!(local.find("chief:cloud-chief").unwrap(), None);
    assert_eq!(local.find("session:codex-chief").unwrap(), None);
    assert_eq!(handle("Hybrid  Chief!", "agent_x"), "hybrid-chief");
    assert_eq!(handle("  ", "agent_x"), "agent_x");
}

#[test]
fn a_tell_posts_into_the_receivers_chat_as_the_sender_and_its_reply_comes_back() {
    let (local, courier, delivered) = chiefs("agent_mux");
    let answer = local
        .tell("chief:Codex Chief", "is main green?", None)
        .unwrap();
    assert!(answer.contains("[chief:codex-chief] report"), "{answer}");
    assert_eq!(
        *courier.sent.lock().unwrap(),
        vec![(
            "conv-agent_01CODEX".to_owned(),
            "chief:chief".to_owned(),
            "is main green?".to_owned()
        )]
    );
    let delivered = delivered.lock().unwrap();
    assert_eq!(delivered.len(), 1);
    assert_eq!(delivered[0].0, "chief:codex-chief");
    assert!(
        delivered[0].1.starts_with("[chief:codex-chief] green on main\n"),
        "{}",
        delivered[0].1
    );
    assert!(delivered[0].1.contains("not the user's"), "{}", delivered[0].1);
}

#[test]
fn it_works_both_ways() {
    let (local, courier, delivered) = chiefs("agent_01CODEX");
    local.tell("chief:chief", "done", None).unwrap();
    assert_eq!(courier.sent.lock().unwrap()[0].0, "conv-agent_mux");
    assert_eq!(courier.sent.lock().unwrap()[0].1, "chief:codex-chief");
    assert_eq!(delivered.lock().unwrap()[0].0, "chief:chief");
}

#[test]
fn a_tell_refuses_itself_a_stranger_an_empty_message_and_a_chief_with_no_chat() {
    let (local, courier, delivered) = chiefs("agent_mux");
    assert!(local.tell("chief:chief", "hi", None).unwrap_err().contains("is you"));
    let unknown = local.tell("chief:nobody", "hi", None).unwrap_err();
    assert!(
        unknown.contains("chief:codex-chief") && unknown.contains("chief:hybrid-chief"),
        "{unknown}"
    );
    assert!(!unknown.contains("chief:chief,"), "{unknown}");
    assert!(local.tell("chief:codex-chief", "  ", None).is_err());
    assert!(
        local
            .tell("chief:hybrid-chief", "hi", None)
            .unwrap_err()
            .contains("no conversation")
    );
    assert!(courier.sent.lock().unwrap().is_empty());
    assert!(delivered.lock().unwrap().is_empty());
}

#[test]
fn a_key_sends_once() {
    let (local, courier, _) = chiefs("agent_mux");
    local.tell("chief:codex-chief", "ping", Some("k1")).unwrap();
    assert!(
        local
            .tell("chief:codex-chief", "ping", Some("k1"))
            .unwrap()
            .contains("already sent")
    );
    assert_eq!(courier.sent.lock().unwrap().len(), 1);
}

#[test]
fn the_list_gives_each_other_local_chief_its_tell_id() {
    let (local, _, _) = chiefs("agent_mux");
    let listed = json!([
        {"id": "agent_mux", "display_name": "Chief"},
        {"id": "agent_01CODEX", "display_name": "Codex Chief"}
    ])
    .to_string();
    let merged = local
        .merge_list(&json!({"action": "list"}), Ok(listed))
        .unwrap();
    let v: Value = serde_json::from_str(&merged).unwrap();
    assert_eq!(v[0]["you"], true);
    assert!(v[0].get("tell_id").is_none());
    assert_eq!(v[1]["tell_id"], "chief:codex-chief");
    assert_eq!(
        v[1]["message_with"],
        "tell(id: \"chief:codex-chief\", message: ...)"
    );
    let get = json!({"action": "get"});
    assert_eq!(local.merge_list(&get, Ok("x".into())).unwrap(), "x");
}

#[test]
fn the_reply_is_the_text_of_the_printed_messages() {
    let out = format!(
        "{}\n{}\nnot json\n",
        json!({"parts": [{"type": "text", "text": "one"}, {"type": "image"}]}),
        json!({"parts": [{"type": "text", "text": "two"}]})
    );
    assert_eq!(reply_text(&out), "one\n\ntwo");
    let note = reply_note(
        &Local {
            id: "agent_01CODEX".into(),
            name: "Codex Chief".into(),
        },
        "",
    );
    assert!(note.starts_with("[chief:codex-chief] (its turn ended with no reply)"));
}

#[test]
fn the_cli_posts_as_the_sender_and_waits_for_the_reply() {
    let args = cli_args(Path::new("/tmp/d.sock"), "conv_1", "chief:chief", "-p looks odd");
    assert_eq!(
        args,
        [
            "--json",
            "--socket",
            "/tmp/d.sock",
            "chief",
            "--prompt=-p looks odd",
            "--from",
            "chief:chief",
            "--chat",
            "conv_1",
            "--timeout",
            "1800"
        ]
    );
}
