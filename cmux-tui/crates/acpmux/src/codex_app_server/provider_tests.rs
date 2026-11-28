use super::*;
use serde_json::json;

fn resume(id: u64) -> Out {
    Out::Server(json!({"jsonrpc":"2.0","id":id,"method":"thread/resume","params":{"threadId":"t"}}))
}
fn server(out: &Out) -> &Value {
    match out {
        Out::Server(v) => v,
        Out::Client(v) => panic!("client message {v}"),
    }
}

#[test]
fn a_resume_waits_for_the_configured_provider_and_names_it() {
    let mut pin = ProviderPin::default();
    let other = Out::Server(json!({"jsonrpc":"2.0","method":"initialized"}));
    let sent = pin.outgoing(vec![
        other,
        resume(7),
        Out::Client(json!({"jsonrpc":"2.0","id":1,"result":{}})),
    ]);
    assert_eq!(sent.len(), 3, "the line before it, the question, and the hub's message");
    assert!(matches!(sent[2], Out::Client(_)), "a message for the hub never waits");
    let ask = server(&sent[1]);
    assert_eq!(ask["method"], "config/read");
    // Anything else from codex is not the answer.
    assert!(pin.answer(&json!({"jsonrpc":"2.0","id":7,"result":{}})).is_none());
    let released = pin
        .answer(&json!({"jsonrpc":"2.0","id":ask["id"],"result":{"config":{"model_provider":"subrouter"}}}))
        .unwrap();
    assert_eq!(released.len(), 1, "the resume");
    assert_eq!(server(&released[0])["params"]["modelProvider"], "subrouter");
    // Later resumes and forks name it at once; one that names its own keeps it.
    let fork = Out::Server(json!({"jsonrpc":"2.0","id":8,"method":"thread/fork","params":{}}));
    let own = Out::Server(
        json!({"jsonrpc":"2.0","id":9,"method":"thread/resume","params":{"modelProvider":"x"}}),
    );
    let sent = pin.outgoing(vec![fork, own]);
    assert_eq!(server(&sent[0])["params"]["modelProvider"], "subrouter");
    assert_eq!(server(&sent[1])["params"]["modelProvider"], "x");
}

#[test]
fn a_codex_that_cannot_answer_gets_the_resume_as_it_was() {
    let mut pin = ProviderPin::default();
    let sent = pin.outgoing(vec![resume(3)]);
    let id = server(&sent[0])["id"].clone();
    let released = pin
        .answer(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"no"}}))
        .unwrap();
    assert!(server(&released[0])["params"].get("modelProvider").is_none());
    // Answered once: no second question.
    let sent = pin.outgoing(vec![resume(4)]);
    assert_eq!(server(&sent[0])["method"], "thread/resume");
}

#[test]
fn a_new_thread_never_waits() {
    let mut pin = ProviderPin::default();
    let start = Out::Server(json!({"jsonrpc":"2.0","id":1,"method":"thread/start","params":{}}));
    let sent = pin.outgoing(vec![start]);
    assert_eq!(server(&sent[0])["method"], "thread/start");
    assert!(pin.asked.is_none());
}
